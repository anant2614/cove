#if os(macOS)
import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

/// Errors thrown by `DictationService.start()`.
public enum DictationError: Error, LocalizedError, Equatable {
    /// Speech recognition or microphone access has not been granted.
    case notAuthorized
    /// No speech recognizer is available for the current locale.
    case recognizerUnavailable
    /// On-device recognition is not supported and server fallback is disabled.
    case onDeviceUnsupported

    /// A user-facing description of the error.
    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Dictation needs Microphone and Speech Recognition permission."
        case .recognizerUnavailable:
            return "Speech recognition is not available right now."
        case .onDeviceUnsupported:
            return "On-device speech recognition is not supported for this language."
        }
    }
}

/// Live dictation using Apple's Speech framework, on-device by default.
@MainActor
public final class DictationService: ObservableObject {
    /// The transcript of the current (or most recent) dictation session.
    @Published public var transcript: String = ""
    /// Whether audio is currently being recorded.
    @Published public var isRecording: Bool = false
    /// The last error, as a user-facing message.
    @Published public var error: String?

    /// When `true`, dictation falls back to Apple's servers if on-device
    /// recognition is not supported for the locale. Defaults to `false` so
    /// audio never leaves the Mac.
    public var allowServerFallback: Bool

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Incremented per session so late callbacks from old sessions are ignored.
    private var sessionID = 0

    /// Creates a dictation service for the current locale (falling back to en-US).
    public init(locale: Locale = .current, allowServerFallback: Bool = false) {
        self.allowServerFallback = allowServerFallback
        self.recognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Authorization

    /// Requests Speech Recognition and Microphone access.
    /// - Returns: `true` only if both are granted.
    public func requestAuthorization() async -> Bool {
        let speech = await DictationService.requestSpeechAuthorization()
        guard speech == .authorized else {
            error = DictationError.notAuthorized.errorDescription
            return false
        }
        let mic = await DictationService.requestMicrophoneAccess()
        if !mic {
            error = DictationError.notAuthorized.errorDescription
        }
        return mic
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording

    /// Starts or stops dictation.
    public func toggle() {
        if isRecording {
            stop()
        } else {
            do {
                try start()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Starts recording and live transcription. Clears the previous transcript.
    /// - Throws: `DictationError` or an `AVAudioEngine` start error.
    public func start() throws {
        guard !isRecording else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        else {
            error = DictationError.notAuthorized.errorDescription
            throw DictationError.notAuthorized
        }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            error = DictationError.recognizerUnavailable.errorDescription
            throw DictationError.recognizerUnavailable
        }

        error = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            error = DictationError.onDeviceUnsupported.errorDescription
            guard allowServerFallback else {
                throw DictationError.onDeviceUnsupported
            }
            request.requiresOnDeviceRecognition = false
        }

        let engine = AVAudioEngine()
        DictationService.installTap(on: engine, feeding: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.error = error.localizedDescription
            throw error
        }

        sessionID += 1
        let handler = DictationService.makeResultHandler(service: self, session: sessionID)
        task = recognizer.recognitionTask(with: request, resultHandler: handler)

        audioEngine = engine
        self.request = request
        transcript = ""
        isRecording = true
    }

    /// Stops recording. The final transcript arrives shortly after via `transcript`.
    public func stop() {
        guard isRecording else { return }
        isRecording = false
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        request?.endAudio()
        request = nil
    }

    // MARK: - Callbacks (off the main thread)

    /// A weak reference that can be captured by `@Sendable` closures.
    private final class WeakServiceBox: @unchecked Sendable {
        weak var value: DictationService?
        init(_ value: DictationService) { self.value = value }
    }

    /// Installs the input tap from a nonisolated context so the tap block
    /// (called on the audio thread) is not main-actor isolated.
    private nonisolated static func installTap(on engine: AVAudioEngine, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// Builds the recognition handler from a nonisolated context; the
    /// handler runs on a Speech-framework queue and hops to the main actor.
    private nonisolated static func makeResultHandler(
        service: DictationService,
        session: Int
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        let box = WeakServiceBox(service)
        return { result, error in
            let text: String? = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message: String? = error?.localizedDescription
            Task { @MainActor in
                guard let service = box.value else { return }
                service.handleResult(text: text, isFinal: isFinal, errorMessage: message, session: session)
            }
        }
    }

    private func handleResult(text: String?, isFinal: Bool, errorMessage: String?, session: Int) {
        guard session == sessionID else { return }
        if let text {
            transcript = text
        }
        if let errorMessage {
            // Errors after the user stopped (e.g. "no speech detected") are
            // only surfaced when nothing was transcribed.
            if isRecording || transcript.isEmpty {
                error = errorMessage
            }
        }
        if isFinal || errorMessage != nil {
            if isRecording { stop() }
            task = nil
        }
    }
}
#endif
