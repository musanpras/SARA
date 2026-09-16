import AVFoundation
import Foundation
import SARACore
import Speech

/// Wake-word detection for the MVP, built on Apple's on-device speech
/// recogniser.
///
/// It runs entirely locally: recognition is pinned to the device when the model
/// supports it, and nothing but the fact that the phrase was heard ever leaves
/// this type. It is a stand-in for a dedicated keyword-spotting model — because
/// it sits behind `WakeWordDetecting`, that swap later touches nothing else.
///
/// Only one recogniser may own the microphone at a time, so the coordinator
/// always stops this before opening a command capture and restarts it after.
public actor SpeechWakeWordDetector: WakeWordDetecting {
    private let recognizer: SFSpeechRecognizer?
    private let matcher: WakeWordMatcher
    private let audioEngine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<WakeWordEvent>.Continuation?
    private var active = false

    public init(phrase: String, locale: Locale = .autoupdatingCurrent) {
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.matcher = WakeWordMatcher(phrase: phrase)
    }

    public func start() async -> AsyncStream<WakeWordEvent> {
        AsyncStream { continuation in
            Task { await self.begin(continuation) }
        }
    }

    public func stop() async {
        active = false
        teardown()
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    private func begin(_ continuation: AsyncStream<WakeWordEvent>.Continuation) async {
        self.continuation = continuation
        active = true

        // Authorization is the command path's responsibility to request; here we
        // only read it, so wake detection degrades to a clear failure rather
        // than a silent no-op if it was never granted.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            emit(.failed(.permission(PermissionError(capability: .speechRecognition, status: .denied))))
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            emit(.failed(.recognizerUnavailable))
            return
        }
        listen(with: recognizer)
    }

    private func listen(with recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        do {
            try configureAudioSession()
            try startEngine(feeding: request)
        } catch {
            emit(.failed(.audioEngineFailed(error.localizedDescription)))
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let transcript = result?.bestTranscription.formattedString
            let ended = result?.isFinal ?? false
            let failed = error != nil
            Task { await self.handle(transcript: transcript, ended: ended || failed) }
        }
    }

    private func handle(transcript: String?, ended: Bool) {
        guard active else { return }

        if let transcript, let match = matcher.match(in: transcript) {
            emit(.detected(trailingCommand: match.trailingCommand))
            Task { await self.stop() }
            return
        }

        // The recogniser stops itself after a stretch of audio; while wake
        // detection is still wanted, start a fresh pass so listening is
        // effectively continuous without holding one unbounded session open.
        if ended {
            restart()
        }
    }

    private func restart() {
        teardown()
        task = nil
        request = nil
        guard active, let recognizer, recognizer.isAvailable else { return }
        listen(with: recognizer)
    }

    private func emit(_ event: WakeWordEvent) {
        continuation?.yield(event)
        if case .failed = event {
            active = false
            continuation?.finish()
            continuation = nil
            teardown()
        }
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
        input.removeTap(onBus: 0)
        // Clear any input format bound from a prior session (e.g. after speech
        // playback changed the sample rate), then validate before tapping —
        // `installTap` raises an uncatchable NSException on a format mismatch.
        audioEngine.reset()

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "SpeechWakeWordDetector",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The microphone is not available right now."]
            )
        }
        // Passing nil adopts the node's own format, so there is nothing to
        // mismatch against.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func teardown() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
