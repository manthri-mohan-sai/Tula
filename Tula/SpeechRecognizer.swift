import Foundation
import Speech
import AVFoundation
import Combine

/// Live speech-to-text manager with intent-aware transcript processing.
///
/// Beyond raw transcription, this listens for *correction intent* phrases —
/// when the user says things like "scratch that", "never mind", or "clear
/// it", we discard everything up to that point in the transcript. The user
/// can dictate continuously and naturally correct themselves:
///
///   User says: "three fifty at swiggy scratch that five hundred at zomato"
///   Transcript becomes: "five hundred at zomato"
///
/// The processed transcript is the public `transcript` property. Consumers
/// (e.g. QuickLogBar) bind to this and treat it as the user's "final" input.
@MainActor
final class SpeechRecognizer: ObservableObject {

    @Published private(set) var transcript: String = ""
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var permissionDenied: Bool = false
    @Published var errorMessage: String?

    /// True when a background AI correction pass is running on a recently
    /// finalized segment. Observers (e.g. the input capsule glow) can use
    /// this to show that the AI is working in parallel while the user
    /// thinks during a pause. Independent of `isRecording` — corrections
    /// continue even after stop if they were already in-flight.
    @Published private(set) var isCorrecting: Bool = false

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Append-only list of "frozen" transcript segments from finalized
    /// recognition tasks. Each pause-restart in iOS finalizes the current
    /// task — at that moment we move whatever was in `currentPartial`
    /// into this array and start a fresh task.
    ///
    /// **Why append-only matters**: the previous design recomputed the
    /// full transcript from `baseline + " " + currentPartial` on every
    /// partial result. Any race or ordering edge case where `baseline`
    /// was momentarily stale could overwrite prior words. With segments,
    /// once a chunk of speech is finalized it's *immutable* (except for
    /// the optional AI-correction replacement) — there's no path for
    /// later events to wipe it.
    private var segments: [String] = []

    /// Live partial from the currently-active recognition task. Gets
    /// updated on every `result` callback. On `isFinal`, this is
    /// appended to `segments` and reset to empty for the next task.
    private var currentPartial: String = ""

    /// Trigger phrases that clear the transcript up to (and including)
    /// themselves. Ordered roughly by likelihood — common phrases first.
    /// All matching is case-insensitive and whole-phrase (regex word boundaries).
    private static let clearTriggers: [String] = [
        "scratch that",
        "clear it",
        "clear that",
        "delete that",
        "never mind",
        "nevermind",
        "start over",
        "ignore that",
        "cancel that",
        "forget that",
        "erase that",
        "wait no",
        "no wait"
    ]

    init(locale: Locale = Locale(identifier: "en-IN")) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
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

    // MARK: - Recording

    func start() {
        stop()
        transcript = ""
        segments = []
        currentPartial = ""
        errorMessage = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        // Audio + haptic cue: must fire BEFORE the audio session moves
        // to `.measurement` mode for recording. Once that mode is active,
        // `AudioServicesPlaySystemSound` is suppressed (or attenuated to
        // near-inaudible), so playing the start tone after `setCategory`
        // would silently no-op. Order here is intentional.
        SoundEffects.voiceStart()
        Haptics.tap()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start audio session."
            return
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Audio tap reads `recognitionRequest` lazily on each invocation —
        // so when we swap to a new request mid-session (pause restart),
        // the tap automatically routes buffers to the new request without
        // needing to re-install. Keeps the audio engine running continuously
        // across recognition-task restarts.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Couldn't start audio engine."
            stop()
            return
        }
        isRecording = true

        startRecognitionTask()
    }

    /// Spins up a fresh `SFSpeechRecognitionTask` against the (still-running)
    /// audio engine. Called once from `start()`, then re-invoked from the
    /// task's completion handler whenever iOS finalizes the previous task.
    /// The previous task's transcript is frozen into the `segments` array,
    /// and the new task's partials become the new `currentPartial`.
    private func startRecognitionTask() {
        guard let recognizer = speechRecognizer, isRecording else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result = result {
                let raw = result.bestTranscription.formattedString
                let processed = Self.processForIntents(raw)
                Task { @MainActor in
                    // Only update the LIVE partial — never touch frozen segments.
                    // This eliminates any race where a stale callback could
                    // wipe previously-finalized text.
                    self.currentPartial = processed
                    self.refreshTranscript()
                }
            }

            if error != nil {
                // Hard error — give up the session entirely.
                Task { @MainActor in self.stop() }
                return
            }

            if result?.isFinal == true {
                // Freeze the current partial as a segment, then restart.
                // The transition is structured so the new task is in
                // place before MainActor unblocks — keeps the audio
                // engine streaming into a valid request without a gap
                // that could drop early syllables of resumed speech.
                Task { @MainActor in
                    guard self.isRecording else { return }
                    self.finalizeCurrentSegment()
                    self.startRecognitionTask()
                }
            }
        }
    }

    /// Move the live `currentPartial` into the frozen `segments` array
    /// and clear the live string. Called when iOS finalizes a task (pause
    /// detected, session limit reached) or when the user explicitly stops.
    ///
    /// Also kicks off the optional **parallel AI correction** — if Smart
    /// Parsing is enabled and Foundation Models is available, fires an
    /// async cleanup pass on the just-frozen segment. The user keeps
    /// dictating (or pauses to think) while FM corrects "rahul" → "waffle",
    /// "1 20" → "120", etc. When the corrected text comes back, it
    /// replaces the segment in place; the visible transcript updates.
    private func finalizeCurrentSegment() {
        let frozen = currentPartial.trimmingCharacters(in: .whitespaces)
        currentPartial = ""
        if frozen.isEmpty {
            refreshTranscript()
            return
        }
        let index = segments.count
        segments.append(frozen)
        refreshTranscript()

        // Parallel AI correction. The recognition task has already restarted
        // by the time this fires; FM works in the background while the user
        // is paused or speaking. When (and only when) FM returns something
        // genuinely different, we replace the segment and refresh.
        startCorrectionPass(forSegmentAt: index, original: frozen)
    }

    /// Recomputes the public `transcript` from frozen segments + live
    /// partial. Single source of truth: the published value is always
    /// derived from these two pieces of state, never written directly.
    private func refreshTranscript() {
        let segs = segments.joined(separator: " ")
        if currentPartial.isEmpty {
            transcript = segs
        } else if segs.isEmpty {
            transcript = currentPartial
        } else {
            transcript = segs + " " + currentPartial
        }
    }

    /// Background AI correction for a just-frozen segment. Runs only when:
    ///   - The user has Smart Parsing enabled in Settings (default on)
    ///   - Foundation Models is available on this device
    ///   - The segment has at least 3 words (single-word segments are
    ///     almost always one item — no realistic correction value)
    ///
    /// **Why per-segment, not whole transcript?** Correcting one segment
    /// at a time keeps each FM call short, fast (sub-second), and
    /// contained. If FM mis-corrects something, only that pause's text
    /// is affected, not the whole session. Also makes parallelism real
    /// — segment N+1 can start being spoken while FM corrects segment N.
    ///
    /// **Amount-preservation safety net.** The corrected text replaces
    /// the segment only when (a) it differs from the original and (b)
    /// the apparent amount is preserved. If FM's "correction" would
    /// shrink the numeric value below half the original (e.g. "350" →
    /// "50" by dropping the leading digit, or "three fifty" → "fifty"
    /// by treating the ones word as filler), the correction is rejected
    /// and the original transcript stays untouched. Losing the hundreds
    /// component of an amount is far more harmful than missing a
    /// homophone fix — better to keep raw transcription than corrupt it.
    private func startCorrectionPass(forSegmentAt index: Int, original: String) {
        // Gate: only run on iOS 26 with FM available AND user toggle on.
        guard correctionEnabledForSession() else { return }
        // Skip very short segments — no realistic correction value
        // ("on" or "the" as a segment doesn't benefit from FM).
        let wordCount = original.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 3 else { return }

        if #available(iOS 26.0, *) {
            isCorrecting = true
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let corrected = await SmartExpenseParser.correctTranscript(original)
                await MainActor.run {
                    // Decrement the "in-flight" flag regardless of outcome.
                    self.isCorrecting = false

                    guard let corrected,
                          !corrected.isEmpty,
                          corrected != original,
                          index < self.segments.count
                    else { return }

                    // Amount-preservation safety check. If FM's correction
                    // would shrink the apparent numeric value significantly,
                    // it probably dropped a digit during cleanup — refuse
                    // the update and keep the original transcript.
                    guard Self.isCorrectionAmountSafe(
                        original: original,
                        corrected: corrected
                    ) else { return }

                    // Replace the segment in place, then refresh the published
                    // transcript. The next partial result from the live task
                    // will see the updated segments and recompute cleanly.
                    self.segments[index] = corrected
                    self.refreshTranscript()
                }
            }
        }
    }

    /// Returns true if the corrected transcript preserves (or correctly
    /// expands) the apparent amount from the original. Used to reject
    /// FM corrections that would silently shrink the value — the most
    /// damaging failure mode of the cleanup pass.
    ///
    /// Algorithm: extract the largest digit-only number from both strings
    /// AFTER running each through the rule parser's number-word normalizer.
    /// That way "three fifty" in the original counts as 350, not 3 or 50.
    /// Then compare:
    /// - No numbers in either: text-only correction, safe.
    /// - Original had a number, corrected lost it: REJECT (erased the amount).
    /// - Corrected value at least half of original: safe (covers legitimate
    ///   consolidations like "1 20" → "120" where digits change but value grows).
    /// - Corrected value less than half: REJECT (likely a dropped digit).
    static func isCorrectionAmountSafe(original: String,
                                       corrected: String) -> Bool {
        let origNormalized = ExpenseParser.normalizeNumberWords(in: original)
        let origMax = largestNumber(in: origNormalized)
        let correctedMax = largestNumber(in: corrected)

        // No numbers in original — correction is purely textual. Safe.
        if origMax == 0 { return true }

        // Original had a number, corrected has none → correction erased
        // the amount entirely. Definitely unsafe.
        if correctedMax == 0 { return false }

        // Significant shrinkage indicates a likely lost digit. Any
        // reduction below half the original is treated as a correction
        // error. This still allows the "1 20" → "120" case (max grew
        // from 20 to 120) which is what we want to keep.
        return correctedMax >= origMax / 2
    }

    /// Extracts the largest integer present in the string. Returns 0
    /// when there are no digit groups. Used only by the correction
    /// safety check — small helper, kept private to the recognizer.
    private static func largestNumber(in text: String) -> Int {
        let matches = text.matches(of: #/\d+/#)
        var maxValue = 0
        for match in matches {
            if let value = Int(match.output) {
                maxValue = max(maxValue, value)
            }
        }
        return maxValue
    }

    /// Whether correction is enabled for the active session. Reads the
    /// same `smartParsingEnabled` AppStorage value that gates the main
    /// FM voice path — single toggle controls both behaviors.
    @MainActor
    private func correctionEnabledForSession() -> Bool {
        // Read via UserDefaults (same key @AppStorage uses) so we don't
        // need to inject the setting into this class. Simple and avoids
        // coupling. Default true matches the @AppStorage default.
        UserDefaults.standard.object(forKey: "smartParsingEnabled") as? Bool ?? true
    }

    func stop() {
        // Capture pre-stop state so we only play the "end" cue when
        // there was actually a listening session to end. Calling stop()
        // when not recording (e.g. defensive cleanup paths) would
        // otherwise emit a tone out of nowhere.
        let wasRecording = isRecording
        // Set isRecording = false FIRST so any pending isFinal callback
        // from the prior task sees the cleared flag and doesn't try to
        // restart recognition after the user explicitly tapped stop.
        isRecording = false
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        segments = []
        currentPartial = ""

        if wasRecording {
            // Deactivate the audio session BEFORE playing the end tone.
            // While the session is still in `.measurement` mode, system
            // sounds are suppressed — moving the deactivation ahead of
            // the SoundEffects call ensures the tone routes through the
            // normal media output and is actually audible.
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            SoundEffects.voiceEnd()
            Haptics.tap()
        }
    }

    // MARK: - Intent Processing

    /// Strip "clear" intent phrases. Finds the LAST occurrence of any
    /// trigger in the transcript and discards everything up to and
    /// including it. Chains naturally — "X scratch that Y never mind Z"
    /// reduces to just "Z".
    ///
    /// Implementation note: we scan from the end because users typically
    /// say the correction *after* the wrong content. The last-occurrence
    /// rule gives them the freshest input.
    static func processForIntents(_ raw: String) -> String {
        var result = raw

        // Iteratively trim — keep finding and stripping triggers until
        // none remain. Each iteration trims at most one trigger, so the
        // loop terminates in O(n) where n is the number of triggers said.
        var didTrim = true
        while didTrim {
            didTrim = false
            for trigger in clearTriggers {
                if let range = result.range(
                    of: trigger,
                    options: [.caseInsensitive, .backwards]
                ) {
                    result = String(result[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    didTrim = true
                    break   // restart the scan from the top to handle chained triggers
                }
            }
        }

        return result
    }
}
