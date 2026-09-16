import Foundation
import SARACore

/// A speech recogniser that replays a queue of captures, one per `start`.
///
/// Unlike `ScriptedSpeechRecognizer` (which models a single push-to-talk turn),
/// this serves the hands-free loop, where the recogniser opens and closes
/// itself several times in one session. When endpointing is requested — the
/// hands-free path — each capture delivers its partials and its final result
/// immediately, standing in for voice-activity detection ending the utterance.
/// Without endpointing it waits for `stopListening`, so it can also model
/// push-to-talk.
public actor QueuedSpeechRecognizer: SpeechRecognizing {
    public struct Turn: Sendable {
        public var partials: [String]
        public var finalTranscript: String?
        public var confidence: Double?
        public var failure: SpeechError?

        public init(
            partials: [String] = [],
            finalTranscript: String? = nil,
            confidence: Double? = nil,
            failure: SpeechError? = nil
        ) {
            self.partials = partials
            self.finalTranscript = finalTranscript
            self.confidence = confidence
            self.failure = failure
        }

        /// A turn that ends with the given transcript.
        public static func said(_ text: String, confidence: Double? = nil) -> Turn {
            Turn(finalTranscript: text, confidence: confidence)
        }
    }

    private var turns: [Turn]
    private var current: Turn?
    private var continuation: AsyncStream<SpeechEvent>.Continuation?

    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var cancelCount = 0

    public init(turns: [Turn]) {
        self.turns = turns
    }

    public func speechAuthorizationStatus() async -> PermissionStatus { .authorized }
    public func microphoneAuthorizationStatus() async -> PermissionStatus { .authorized }
    public func requestAccess() async -> Result<Void, SpeechError> { .success(()) }

    public func startListening() async -> AsyncStream<SpeechEvent> {
        await startListening(endpointing: nil)
    }

    public func startListening(endpointing: VoiceEndpointingOptions?) async -> AsyncStream<SpeechEvent> {
        startCount += 1
        let (stream, continuation) = AsyncStream<SpeechEvent>.makeStream()
        self.continuation = continuation

        let turn = turns.isEmpty ? Turn(failure: .noSpeechDetected) : turns.removeFirst()
        current = turn

        for partial in turn.partials { continuation.yield(.partialTranscript(partial)) }

        // Endpointing means the recogniser ends the capture itself; deliver the
        // outcome now. Otherwise wait for the caller to stop (push-to-talk).
        if endpointing != nil {
            deliverOutcome(turn)
        }
        return stream
    }

    public func stopListening() async {
        stopCount += 1
        if let turn = current { deliverOutcome(turn) }
    }

    public func cancelListening() async {
        cancelCount += 1
        continuation?.finish()
        continuation = nil
        current = nil
    }

    private func deliverOutcome(_ turn: Turn) {
        if let failure = turn.failure {
            continuation?.yield(.failed(failure))
        } else if let text = turn.finalTranscript {
            continuation?.yield(.finalTranscript(text: text, confidence: turn.confidence))
        }
        continuation?.finish()
        continuation = nil
        current = nil
    }
}
