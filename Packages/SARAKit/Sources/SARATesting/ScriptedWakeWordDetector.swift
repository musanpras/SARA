import Foundation
import SARACore

/// A wake-word engine that replays scripted events, so the hands-free loop can
/// be tested without a microphone.
///
/// Each call to `start()` delivers the next queued event (typically a
/// `.detected`) and then keeps the stream open, mirroring a real engine that
/// only finishes when the phrase is heard or it is stopped. When the queue is
/// empty, `start()` simply waits — which is exactly "listening for the wake word
/// with nothing said yet", and a natural place for a test to end.
public actor ScriptedWakeWordDetector: WakeWordDetecting {
    private var events: [WakeWordEvent]
    private var continuation: AsyncStream<WakeWordEvent>.Continuation?

    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    public init(events: [WakeWordEvent]) {
        self.events = events
    }

    /// Convenience: fire the wake word once with no trailing command.
    public init(detectOnce trailingCommand: String? = nil) {
        self.events = [.detected(trailingCommand: trailingCommand)]
    }

    public func start() async -> AsyncStream<WakeWordEvent> {
        startCount += 1
        let (stream, continuation) = AsyncStream<WakeWordEvent>.makeStream()
        self.continuation = continuation

        if !events.isEmpty {
            let next = events.removeFirst()
            continuation.yield(next)
            // A real detector finishes its stream once the phrase is detected;
            // the coordinator opens a command capture next.
            if case .failed = next { continuation.finish(); self.continuation = nil }
            else { continuation.finish(); self.continuation = nil }
        }
        // Empty queue: leave the stream open (waiting for a wake word).
        return stream
    }

    public func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }
}
