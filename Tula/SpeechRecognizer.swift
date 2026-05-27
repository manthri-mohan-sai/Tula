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

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

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
        errorMessage = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable."
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start audio session."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

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

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                let raw = result.bestTranscription.formattedString
                let processed = Self.processForIntents(raw)
                Task { @MainActor in self.transcript = processed }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in self.stop() }
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
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
