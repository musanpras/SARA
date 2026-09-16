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

    /// Present only for hands-free captures. When set, buffer amplitude is fed
    /// to it and the capture ends itself on end-of-speech; when nil the caller
    /// ends the capture (push-to-talk).
    private var detector: VoiceActivityDetector?
    /// Fires the hard time limit so an open microphone cannot listen forever.
    private var timeoutTask: Task<Void, Never>?
    /// True once end-of-speech (or the timeout) has asked for a final result, so
    /// the request is only ended once.
    private var didRequestEnd = false

    /// Endpointing on the recogniser's own output, as a robust complement to the
    /// amplitude VAD: once there is a transcript that has stopped changing for
    /// `endpointSilence`, the utterance is finished even if the microphone's RMS
    /// never crossed the VAD thresholds on this device. Nil for push-to-talk with
    /// no endpointing requested... though the button path now requests it too.
    private var endpointSilence: TimeInterval?
    private var lastPartialText = ""
    private var lastPartialAt: TimeInterval?

    private static func monotonicNow() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Token for the audio-interruption observer, removed when the manager goes
    /// away. `nonisolated(unsafe)` only because the token is written once from
    /// the actor and read once in the nonisolated deinit; it is never raced.
    nonisolated(unsafe) private var interruptionObserver: (any NSObjectProtocol)?

    public init(locale: Locale = .autoupdatingCurrent) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        Task { await self.observeInterruptions() }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - Interruptions

    /// Ends an in-flight capture when the system takes the audio session — a
    /// phone call, Siri, an alarm. The capture fails cleanly rather than
    /// hanging on a dead engine; the view model surfaces the message and, in a
    /// hands-free session, recovers by returning to the wake word.
    private func observeInterruptions() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard
                let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: value) == .began
            else { return }
            Task { await self?.audioWasInterrupted() }
        }
        #endif
    }

    private func audioWasInterrupted() {
        // Only meaningful while a capture is actually running.
        guard continuation != nil, !didDeliverFinalResult else { return }
        finish(with: .failed(.underlying("Audio was interrupted.")))
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
        await startListening(endpointing: nil)
    }

    public func startListening(endpointing: VoiceEndpointingOptions?) async -> AsyncStream<SpeechEvent> {
        AsyncStream { continuation in
            Task { await self.begin(with: continuation, endpointing: endpointing) }
        }
    }

    private func begin(
        with continuation: AsyncStream<SpeechEvent>.Continuation,
        endpointing: VoiceEndpointingOptions?
    ) async {
        self.continuation = continuation
        didDeliverFinalResult = false
        didRequestEnd = false
        detector = endpointing.map { VoiceActivityDetector(configuration: $0.detection) }
        endpointSilence = endpointing?.detection.endOfSpeechSilenceDuration
        lastPartialText = ""
        lastPartialAt = nil

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
            try startEngine(feeding: request, endpointed: endpointing != nil)
        } catch {
            finish(with: .failed(.audioEngineFailed(error.localizedDescription)))
            return
        }

        // The hard ceiling. Without a button to release, a capture that never
        // hears end-of-speech (silence, or noise the VAD keeps rejecting) still
        // has to end; the recogniser then delivers whatever it has, or reports
        // that it heard nothing.
        if let endpointing {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(endpointing.maximumDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.endDueToEndpoint()
            }
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

            // Note when the transcript last grew, so endpointing can finalise
            // once the recogniser has been quiet for the silence window.
            let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != lastPartialText {
                lastPartialText = trimmed
                lastPartialAt = Self.monotonicNow()
            }
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

    private func startEngine(
        feeding request: SFSpeechAudioBufferRecognitionRequest,
        endpointed: Bool
    ) throws {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        // A fresh reset clears any input format left bound from a previous
        // session — notably after text-to-speech ran the session in `.playback`
        // at a different sample rate.
        audioEngine.reset()

        // `installTap` throws an *NSException* on a format mismatch, which Swift
        // cannot catch, so the format is validated first (a dead route reports
        // zero here) and then the tap adopts the node's own format by passing
        // `nil` — there is nothing to mismatch against.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "SpeechManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The microphone is not available right now."]
            )
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            request.append(buffer)
            // Voice-activity detection runs off the same buffers that feed the
            // recogniser, so end-of-speech is measured on the real audio rather
            // than inferred from recognition callbacks. The amplitude is a pure
            // computation on the audio thread; only the decision hops onto the
            // actor.
            guard endpointed, let self else { return }
            let level = Self.rms(of: buffer)
            let time = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            Task { await self.observe(level: level, at: time) }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Feeds one amplitude reading to the detector and ends the capture when it
    /// reports the utterance is complete.
    private func observe(level: Float, at time: TimeInterval) {
        guard detector != nil else { return }
        let event = detector!.process(level: level, at: time)
        if event == .endOfUtterance {
            endDueToEndpoint()
            return
        }

        // Recogniser-driven endpointing: if we already have a transcript and it
        // has stopped changing for the silence window, end now. This carries the
        // common case even when device gain keeps RMS below the VAD thresholds.
        if let silence = endpointSilence,
           !lastPartialText.isEmpty,
           let last = lastPartialAt,
           time - last >= silence {
            endDueToEndpoint()
        }
    }

    /// Ends the audio and asks the recogniser for a final result, exactly once,
    /// whether the trigger was end-of-speech or the timeout.
    private func endDueToEndpoint() {
        guard !didRequestEnd, !didDeliverFinalResult else { return }
        didRequestEnd = true
        timeoutTask?.cancel()
        timeoutTask = nil
        teardownAudio()
        request?.endAudio()
    }

    /// Root-mean-square amplitude of a buffer, 0...1. The loudness measure the
    /// VAD compares against its thresholds.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sum += sample * sample
        }
        return (sum / Float(frames)).squareRoot()
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
        timeoutTask?.cancel()
        timeoutTask = nil
        detector = nil
        endpointSilence = nil
        lastPartialText = ""
        lastPartialAt = nil
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
