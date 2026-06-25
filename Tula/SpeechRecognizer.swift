import Foundation
import Speech
import AVFoundation
import Combine

/// Live speech-to-text engine for dictating expenses.
///
/// This is the **capture** stage of voice logging: audio → text. The text it
/// produces is then handed to the parser stage (rule parser + LLM) which turns
/// it into a structured expense. Because the parser only ever sees this text —
/// never the audio — the accuracy of this stage is the ceiling on everything
/// downstream. A dropped amount here can't be recovered later.
///
/// ## Design goals (rewrite, iOS 18 floor)
///
/// 1. **Adaptive recognition.** Prefer Apple's *server* recognizer (markedly
///    more accurate, same engine as Dictation) and fall back to the on-device
///    model automatically when offline / when the network path errors. The
///    previous implementation forced on-device unconditionally, which is both
///    less accurate and silently broken when the locale's on-device asset
///    isn't installed.
///
/// 2. **Race-free.** Every async recognition callback is tagged with the
///    `generation` it belongs to. `stop()` (and each `start()`) bumps the
///    generation, so any in-flight or queued callback from a prior session is
///    a single-line no-op. This replaces the previous design's scattered
///    `guard isRecording` patches, each of which only covered one specific
///    race window.
///
/// 3. **No partial-result flicker.** "Clear" intent phrases ("scratch that")
///    are stripped only against *finalized* text — never against the volatile
///    live partial, which the recognizer freely revises. Finalized text is
///    immutable, so the visible transcript only ever grows or is cleared by a
///    real correction phrase; it never wipes-then-restores under the user.
///
/// 4. **Survives interruptions.** A phone call, Siri, or an unplugged headset
///    used to silently kill the audio session mid-sentence. We now observe
///    interruption / route-change notifications and end the session cleanly
///    with a user-visible message instead of appearing to "just stop working".
///
/// The processed transcript is the public `transcript` property. Consumers
/// (QuickLogBar) bind to it and treat it as the user's input.
@MainActor
final class SpeechRecognizer: ObservableObject {

    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var permissionDenied: Bool = false
    @Published var errorMessage: String?

    /// True while a one-shot AI cleanup pass runs on the *finalized* transcript
    /// after the user stops talking. Observers (the input-capsule glow) use it
    /// to show that AI is still working. Unlike the previous design this never
    /// runs mid-recording, so it can't rewrite text under the user's eyes.
    @Published private(set) var isCorrecting: Bool = false

    /// Contextual phrases that bias recognition toward the user's vocabulary —
    /// merchant names, account names, category names, learned corrections.
    /// Set by the caller before `start()`. Injected into every request via
    /// `contextualStrings` so the recognizer prefers "Sagar Ratna" over
    /// "sugar rata" when audio is ambiguous. Capped at Apple's limit of 100.
    var contextualPhrases: [String] = []

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Monotonic session token. Bumped on every `start()` and `stop()`. Each
    /// recognition callback captures the generation it was created under and
    /// bails immediately if it no longer matches — the single, central guard
    /// against stale callbacks corrupting state after a stop/restart.
    private var generation = 0

    /// Finalized transcript so far, with "clear" intents already applied.
    /// Append-only across a session except when an intent phrase clears it.
    /// Immutable per-segment: once recognition finalizes a chunk it lands here
    /// and is never revised, which is what keeps the UI from flickering.
    private var committedText = ""

    /// The live, still-being-revised partial from the active task. Shown raw
    /// (no intent stripping) and replaced wholesale on every partial result.
    private var volatilePartial = ""

    /// Adaptive-recognition state. We start each session preferring the server
    /// recognizer (`false`). If a task errors before producing any text and an
    /// on-device model exists, we flip this and restart once — covering the
    /// offline / no-network case without the user noticing.
    private var requireOnDevice = false
    private var didFallBackToOnDevice = false

    /// Interruption / route-change observers, removed on deinit.
    private var sessionObservers: [NSObjectProtocol] = []

    /// Trigger phrases that clear everything up to and including themselves.
    /// Whole-phrase, case-insensitive. Applied only to finalized text.
    private static let clearTriggers: [String] = [
        "scratch that", "clear it", "clear that", "delete that",
        "never mind", "nevermind", "start over", "ignore that",
        "cancel that", "forget that", "erase that", "wait no", "no wait"
    ]

    init(locale: Locale = Locale(identifier: "en-IN")) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        registerSessionObservers()
    }

    deinit {
        for token in sessionObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard speechStatus == .authorized else {
            permissionDenied = true
            return false
        }

        let micGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
        permissionDenied = !micGranted
        return micGranted
    }

    // MARK: - Recording lifecycle

    func start() {
        // Tear down any prior session first; this also bumps the generation so
        // stale callbacks from a previous run are neutralized.
        stop()

        // New session.
        generation &+= 1
        transcript = ""
        committedText = ""
        volatilePartial = ""
        errorMessage = nil
        requireOnDevice = false
        didFallBackToOnDevice = false

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        // Play the start tone and wait for it to finish before touching the
        // audio session — switching to a recording category mid-tone silences
        // it. The completion handler ensures the full cue is audible.
        Haptics.tap()
        let gen = generation
        SoundEffects.voiceStart { [weak self] in
            // The completion fires on the main queue (see SoundEffects), so we
            // can assert main-actor isolation rather than hop through a Task.
            MainActor.assumeIsolated {
                // If the user already stopped (or restarted) during the ~200ms
                // tone, this session is stale — don't open the mic.
                guard let self, self.generation == gen else { return }
                self.beginRecordingSession()
            }
        }
    }

    /// Configures the audio session, installs the mic tap, and starts the
    /// first recognition task. The audio engine then runs continuously for the
    /// whole session — recognition tasks are restarted under it without ever
    /// stopping the engine, so no audio is dropped at task boundaries.
    private func beginRecordingSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // `.record`: we only capture here (start/end tones play outside the
            // active window). `.measurement` is Apple's recommended mode for
            // speech recognition. `.duckOthers` lowers background audio so the
            // mic hears the user. We deliberately do NOT opt into Bluetooth
            // HFP — its narrowband (8–16 kHz) audio recognizes worse than the
            // built-in mic, so letting the system pick the wired/built-in route
            // yields more accurate transcription.
            try audioSession.setCategory(.record,
                                         mode: .measurement,
                                         options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start audio session."
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against a degenerate input format (0 sample rate / 0 channels),
        // which happens when no usable input route exists. Installing a tap
        // with such a format throws an exception that would crash the app.
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            errorMessage = "No microphone input available."
            teardownAudio(deactivateSession: true)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            // The tap runs on a realtime audio thread. Feed the *current*
            // request directly (no hop) — appending is thread-safe and the
            // request reference is swapped atomically on the main actor during
            // restarts, so we always feed whichever task is live.
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Couldn't start audio engine."
            teardownAudio(deactivateSession: true)
            return
        }

        isRecording = true
        startRecognitionTask()
    }

    /// Spins up a fresh recognition task against the running audio engine.
    /// Called once from `beginRecordingSession()` and re-invoked whenever the
    /// system finalizes the current task (a pause, or the server's segment
    /// limit) so capture continues seamlessly.
    private func startRecognitionTask() {
        guard let recognizer = speechRecognizer, isRecording else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) {
            // Let the recognizer insert punctuation. Cleaner text → better
            // downstream parsing, and a more natural live preview.
            request.addsPunctuation = true
        }

        // Adaptive: use the server recognizer when possible (higher accuracy),
        // only forcing on-device after a network-class failure or when the
        // device has no server path. `requireOnDevice` is flipped by the
        // fallback logic below.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = requireOnDevice
        } else {
            request.requiresOnDeviceRecognition = false
        }

        // Bias recognition toward the user's vocabulary.
        if !contextualPhrases.isEmpty {
            request.contextualStrings = Array(contextualPhrases.prefix(100))
        }

        recognitionRequest = request

        // Capture the generation this task belongs to. Every branch of the
        // callback checks it before mutating state.
        let gen = generation

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor in
                    guard self.generation == gen, self.isRecording else { return }
                    if isFinal {
                        self.commit(segment: text)
                        self.volatilePartial = ""
                        self.refreshTranscript()
                        // Continue capturing — start the next task seamlessly.
                        self.startRecognitionTask()
                    } else {
                        self.volatilePartial = text
                        self.refreshTranscript()
                    }
                }
            }

            if let error {
                Task { @MainActor in
                    guard self.generation == gen, self.isRecording else { return }
                    self.handleRecognitionError(error)
                }
            }
        }
    }

    /// Handles a recognition task error. The key recovery path: if we were
    /// using the server recognizer, nothing has been transcribed yet, and an
    /// on-device model exists, transparently retry on-device (offline case).
    /// Otherwise end the session, preserving whatever was already committed.
    private func handleRecognitionError(_ error: Error) {
        let canFallBack = !requireOnDevice
            && !didFallBackToOnDevice
            && committedText.isEmpty
            && (speechRecognizer?.supportsOnDeviceRecognition ?? false)

        if canFallBack {
            // Flip to on-device and restart the task under the still-running
            // audio engine. The user never sees the hiccup.
            didFallBackToOnDevice = true
            requireOnDevice = true
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            startRecognitionTask()
            return
        }

        // Unrecoverable. If we already captured text, keep it and end quietly;
        // only surface an error when the session produced nothing usable.
        if committedText.isEmpty && volatilePartial.isEmpty {
            errorMessage = "Couldn't hear that. Try again."
        }
        finish(playEndCue: false)
    }

    /// Public stop — user tapped the stop control. Plays the end cue.
    func stop() {
        finish(playEndCue: isRecording)
    }

    /// Centralized teardown. Bumps the generation (neutralizing every pending
    /// callback), stops audio, and optionally plays the end cue + runs the
    /// one-shot AI cleanup on the finalized transcript.
    private func finish(playEndCue: Bool) {
        let wasRecording = isRecording

        // Invalidate all in-flight callbacks atomically.
        generation &+= 1
        isRecording = false

        teardownAudio(deactivateSession: wasRecording)

        if wasRecording {
            SoundEffects.voiceEnd()
            Haptics.tap()
        }

        // Fold any trailing live partial into the committed text so nothing
        // the user said right before stopping is lost.
        if !volatilePartial.isEmpty {
            commit(segment: volatilePartial)
            volatilePartial = ""
            refreshTranscript()
        }

        if wasRecording {
            runFinalCorrectionPass()
        }
    }

    /// Stops the audio engine and recognition task. Safe to call repeatedly.
    private func teardownAudio(deactivateSession: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        if deactivateSession {
            // Deactivate BEFORE any end cue so the tone routes through normal
            // media output rather than being suppressed by the recording mode.
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    }

    // MARK: - Transcript assembly

    /// Append a finalized segment to `committedText`, applying clear-intent
    /// phrases across the *combined* finalized text. Operating only on
    /// finalized (immutable) text means intent stripping can never flicker.
    private func commit(segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let merged = committedText.isEmpty ? trimmed : committedText + " " + trimmed
        committedText = Self.processForIntents(merged)
    }

    /// Recompute the published transcript from committed text + the live
    /// partial. Single source of truth — `transcript` is never written
    /// directly anywhere else.
    private func refreshTranscript() {
        let live = volatilePartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if live.isEmpty {
            transcript = committedText
        } else if committedText.isEmpty {
            transcript = live
        } else {
            transcript = committedText + " " + live
        }
    }

    // MARK: - One-shot AI correction (post-stop, iOS 26+)

    /// After recording ends, optionally run a single conservative AI cleanup
    /// pass over the finalized transcript (homophones, split digits). Runs
    /// only when Smart Parsing is on and Foundation Models is available. Never
    /// runs mid-recording, and is rejected if it would shrink the apparent
    /// amount (a dropped-digit safety net).
    private func runFinalCorrectionPass() {
        guard correctionEnabledForSession() else { return }
        let original = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard original.split(whereSeparator: { $0.isWhitespace }).count >= 3 else { return }

        guard #available(iOS 26.0, *) else { return }
        let gen = generation
        isCorrecting = true
        Task { @MainActor in
            let corrected = await SmartExpenseParser.correctTranscript(original)
            // A new session may have started while we awaited; only apply if
            // we're still idle on the same generation and nothing new was said.
            guard self.generation == gen, !self.isRecording else {
                self.isCorrecting = false
                return
            }
            self.isCorrecting = false
            guard let corrected,
                  !corrected.isEmpty,
                  corrected != original,
                  Self.isCorrectionAmountSafe(original: original, corrected: corrected)
            else { return }
            self.committedText = corrected
            self.refreshTranscript()
        }
    }

    /// Reads the same `smartParsingEnabled` flag the main FM voice path uses.
    private func correctionEnabledForSession() -> Bool {
        UserDefaults.standard.object(forKey: "smartParsingEnabled") as? Bool ?? true
    }

    // MARK: - Interruptions & route changes

    /// Observe audio-session interruptions (calls, Siri) and route changes
    /// (headset unplugged). Any of these can render the mic dead mid-session;
    /// we end cleanly and tell the user rather than appearing to hang.
    private func registerSessionObservers() {
        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .began else { return }
            // Registered with `queue: .main`, so the block runs on the main
            // actor — assert it rather than deferring through a Task.
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.errorMessage = "Recording interrupted."
                self.finish(playEndCue: false)
            }
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.finish(playEndCue: false)
            }
        }

        sessionObservers = [interruption, routeChange]
    }

    // MARK: - Intent processing

    /// Strip "clear" intent phrases. Finds the LAST occurrence of any trigger
    /// and discards everything up to and including it. Chains naturally:
    /// "X scratch that Y never mind Z" reduces to "Z". Applied only to
    /// finalized text by `commit(segment:)`.
    static func processForIntents(_ raw: String) -> String {
        var result = raw
        var didTrim = true
        while didTrim {
            didTrim = false
            for trigger in clearTriggers {
                if let range = result.range(of: trigger, options: [.caseInsensitive, .backwards]) {
                    result = String(result[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    didTrim = true
                    break
                }
            }
        }
        return result
    }

    // MARK: - Correction safety

    /// True if a corrected transcript preserves (or correctly expands) the
    /// apparent amount. Rejects corrections that would silently shrink the
    /// value — the most damaging failure mode of an AI cleanup pass.
    static func isCorrectionAmountSafe(original: String, corrected: String) -> Bool {
        let origMax = largestNumber(in: ExpenseParser.normalizeNumberWords(in: original))
        let correctedMax = largestNumber(in: ExpenseParser.normalizeNumberWords(in: corrected))
        if origMax == 0 { return true }
        if correctedMax == 0 { return false }
        return correctedMax >= origMax / 2
    }

    private static func largestNumber(in text: String) -> Int {
        var maxValue = 0
        for match in text.matches(of: #/\d+/#) {
            if let value = Int(match.output) { maxValue = max(maxValue, value) }
        }
        return maxValue
    }
}
