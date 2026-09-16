import Foundation
import SARACore

/// A speech recogniser that replays a scripted sequence of events.
///
/// Push-to-talk has real sequencing — partial results, a final transcript on
/// release, failures part-way through — and none of it should need a
/// microphone to test.
public actor ScriptedSpeechRecognizer: SpeechRecognizing {
    /// Events delivered as soon as listening starts.
    private let immediate: [SpeechEvent]
    /// Events delivered when the caller stops listening, which is where a real
    /// recogniser produces its final transcript.
    private let onStop: [SpeechEvent]
    private var speechStatus: PermissionStatus
    private var microphoneStatus: PermissionStatus

    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var cancelCount = 0

    public init(
        partials: [String] = [],
        finalTranscript: String? = nil,
        confidence: Double? = nil,
        failure: SpeechError? = nil,
        speechStatus: PermissionStatus = .authorized,
        microphoneStatus: PermissionStatus = .authorized
    ) {
        self.immediate = partials.map { .partialTranscript($0) }
        if let failure {
            self.onStop = [.failed(failure)]
        } else if let finalTranscript {
            self.onStop = [.finalTranscript(text: finalTranscript, confidence: confidence)]
        } else {
            self.onStop = []
        }
        self.speechStatus = speechStatus
        self.microphoneStatus = microphoneStatus
    }

    public func speechAuthorizationStatus() async -> PermissionStatus { speechStatus }
    public func microphoneAuthorizationStatus() async -> PermissionStatus { microphoneStatus }

    public func requestAccess() async -> Result<Void, SpeechError> {
        if speechStatus == .notDetermined { speechStatus = .authorized }
        if microphoneStatus == .notDetermined { microphoneStatus = .authorized }

        guard speechStatus.canRead else {
            return .failure(.permission(PermissionError(capability: .speechRecognition, status: speechStatus)))
        }
        guard microphoneStatus.canRead else {
            return .failure(.permission(PermissionError(capability: .microphone, status: microphoneStatus)))
        }
        return .success(())
    }

    public func startListening() async -> AsyncStream<SpeechEvent> {
        startCount += 1

        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        self.continuation = continuation

        if case .failure(let error) = await requestAccess() {
            continuation.yield(.failed(error))
            continuation.finish()
            self.continuation = nil
            return stream
        }

        for event in immediate { continuation.yield(event) }
        return stream
    }

    public func stopListening() async {
        stopCount += 1
        for event in onStop { continuation?.yield(event) }
        continuation?.finish()
        continuation = nil
    }

    public func cancelListening() async {
        cancelCount += 1
        continuation?.finish()
        continuation = nil
    }
}
