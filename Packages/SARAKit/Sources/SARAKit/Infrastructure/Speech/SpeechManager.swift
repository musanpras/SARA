import AVFoundation
import Foundation
import SARACore
import Speech

/// Push-to-talk speech recognition using Apple's Speech framework.
///
/// An actor because the audio engine, the recognition task and the event
/// stream are all touched from different contexts. Permissions are requested
/// here, at the moment the microphone is first used, rather than at launch.
public actor SpeechManager: SpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var didDeliverFinalResult = false

    public init(locale: Locale = .autoupdatingCurrent) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    // MARK: - Authorization

    public func speechAuthorizationStatus() async -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    public func microphoneAuthorizationStatus() async -> PermissionStatus {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .notDetermined
        case .denied: .denied
        case .granted: .authorized
        @unknown default: .denied
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .denied
        }
        #endif
    }

    public func requestAccess() async -> Result<Void, SpeechError> {
        if await speechAuthorizationStatus().isPromptable {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        let speechStatus = await speechAuthorizationStatus()
        guard speechStatus.canRead else {
            return .failure(.permission(PermissionError(capability: .speechRecognition, status: speechStatus)))
        }

        if await microphoneAuthorizationStatus().isPromptable {
            _ = await requestMicrophone()
        }
        let microphoneStatus = await microphoneAuthorizationStatus()
        guard microphoneStatus.canRead else {
            return .failure(.permission(PermissionError(capability: .microphone, status: microphoneStatus)))
        }

        return .success(())
    }

    private func requestMicrophone() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    // MARK: - Listening

    public func startListening() async -> AsyncStream<SpeechEvent> {
        AsyncStream { continuation in
            Task { await self.begin(with: continuation) }
        }
    }

    private func begin(with continuation: AsyncStream<SpeechEvent>.Continuation) async {
        self.continuation = continuation
        didDeliverFinalResult = false

        if case .failure(let error) = await requestAccess() {
            finish(with: .failed(error))
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            finish(with: .failed(.recognizerUnavailable))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keeping recognition on device is both a privacy and an offline win;
        // the recogniser falls back to its server path only if it must.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        do {
            try configureAudioSession()
            try startEngine(feeding: request)
        } catch {
            finish(with: .failed(.audioEngineFailed(error.localizedDescription)))
            return
        }

        // The recogniser's result type is not Sendable, so everything the actor
        // needs is read here and only value types cross the isolation boundary.
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let update = result.map {
                Transcription(
                    text: $0.bestTranscription.formattedString,
                    isFinal: $0.isFinal,
                    confidence: Self.confidence(of: $0)
                )
            }
            let message = error?.localizedDescription
            Task { await self.handle(update, errorMessage: message) }
        }
    }

    /// A Sendable snapshot of one recognition callback.
    private struct Transcription: Sendable {
        let text: String
        let isFinal: Bool
        let confidence: Double?
    }

    private func handle(_ update: Transcription?, errorMessage: String?) {
        if let update {
            if update.isFinal {
                deliverFinal(text: update.text, confidence: update.confidence)
                return
            }
            continuation?.yield(.partialTranscript(update.text))
        }

        guard let errorMessage else { return }
        // A recogniser error after a final result has already been delivered is
        // just teardown noise and must not overwrite a good transcript.
        guard !didDeliverFinalResult else { return }
        finish(with: .failed(.underlying(errorMessage)))
    }

    public func stopListening() async {
        teardownAudio()
        // `endAudio` asks the recogniser to settle; the final result arrives
        // through the callback. A transcript already gathered is not discarded.
        request?.endAudio()
    }

    public func cancelListening() async {
        teardownAudio()
        task?.cancel()
        finish(with: nil)
    }

    // MARK: - Audio plumbing

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startEngine(feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func teardownAudio() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func deliverFinal(text: String, confidence: Double?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        didDeliverFinalResult = true
        finish(with: trimmed.isEmpty
            ? .failed(.noSpeechDetected)
            : .finalTranscript(text: trimmed, confidence: confidence))
    }

    private func finish(with event: SpeechEvent?) {
        if let event { continuation?.yield(event) }
        continuation?.finish()
        continuation = nil
        task = nil
        request = nil
        teardownAudio()
    }

    /// Mean confidence across recognised segments, when the recogniser offers
    /// one. Segments scored zero are unscored rather than certainly wrong.
    private static func confidence(of result: SFSpeechRecognitionResult) -> Double? {
        let scores = result.bestTranscription.segments
            .map { Double($0.confidence) }
            .filter { $0 > 0 }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}
