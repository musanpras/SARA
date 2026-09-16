import Foundation

/// What the detector concludes about the microphone at one instant.
public enum VoiceActivityEvent: Equatable, Sendable {
    /// Quiet, and nothing meaningful has been said yet.
    case silence
    /// The first buffer that crossed the onset threshold.
    case speechStarted
    /// Speech is ongoing (including a short pause that has not yet ended it).
    case speaking
    /// Real speech happened and has now been followed by enough silence to
    /// treat the utterance as complete. This is the signal to stop recording.
    case endOfUtterance
}

/// A deterministic, local voice-activity detector.
///
/// It is deliberately free of AVFoundation: it consumes a sequence of RMS
/// amplitude readings with timestamps and decides, with hysteresis and a
/// minimum-speech guard, when an utterance has ended. Keeping the decision
/// logic pure is what makes end-of-speech testable without a microphone — the
/// audio layer's only job is to hand it `level` and `time`.
///
/// The prompt calls out that recogniser completion callbacks are not a reliable
/// substitute for explicit end-of-speech control; this is that explicit
/// control.
public struct VoiceActivityDetector: Sendable {
    private let configuration: VoiceDetectionConfiguration

    /// Adaptive estimate of the room's quiet level. Seeded pessimistically low
    /// so the very first words are never swallowed while it settles.
    private var noiseFloor: Float = 0
    private var hasSeededNoiseFloor = false

    /// True once the current amplitude has crossed onset and not yet released.
    private var inSpeech = false
    /// Total time attributed to speech in this utterance, for the minimum-speech
    /// guard.
    private var accumulatedSpeech: TimeInterval = 0
    /// True once accumulated speech has passed `minimumSpeechDuration`.
    private var hasRealSpeech = false

    /// Timestamp of the most recent buffer counted as speech.
    private var lastSpeechTime: TimeInterval?
    /// Timestamp of the previous reading, for measuring elapsed time.
    private var lastTime: TimeInterval?
    /// Set once `endOfUtterance` has fired, so it is reported exactly once.
    private var finished = false

    public init(configuration: VoiceDetectionConfiguration) {
        self.configuration = configuration
    }

    /// Feeds one amplitude reading and returns the current conclusion.
    ///
    /// - Parameters:
    ///   - level: linear RMS amplitude of the buffer, 0...1.
    ///   - time: a monotonically increasing timestamp in seconds.
    public mutating func process(level: Float, at time: TimeInterval) -> VoiceActivityEvent {
        if finished { return .endOfUtterance }

        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        seedOrAdaptNoiseFloor(with: level)

        // Hysteresis: it takes `onsetThreshold` above the floor to begin, but
        // only dropping below `releaseThreshold` to stop. The band between them
        // holds the state steady when a voice hovers near the line.
        let onset = noiseFloor + configuration.onsetThreshold
        let release = noiseFloor + configuration.releaseThreshold

        let justStarted: Bool
        if inSpeech {
            if level < release { inSpeech = false }
            justStarted = false
        } else {
            if level > onset {
                inSpeech = true
                justStarted = !hasRealSpeech && accumulatedSpeech == 0
            } else {
                justStarted = false
            }
        }

        if inSpeech {
            accumulatedSpeech += elapsed
            lastSpeechTime = time
            if accumulatedSpeech >= configuration.minimumSpeechDuration {
                hasRealSpeech = true
            }
            return justStarted ? .speechStarted : .speaking
        }

        // Silent buffer. Only meaningful once real speech has occurred.
        guard hasRealSpeech, let lastSpeech = lastSpeechTime else {
            return .silence
        }

        if time - lastSpeech >= configuration.endOfSpeechSilenceDuration {
            finished = true
            return .endOfUtterance
        }
        // A pause too short to end the turn still counts as part of the
        // utterance, so downstream sees continuity rather than a stop-start.
        return .speaking
    }

    /// True once the detector has declared the utterance finished.
    public var didFinish: Bool { finished }

    private mutating func seedOrAdaptNoiseFloor(with level: Float) {
        guard hasSeededNoiseFloor else {
            // Cap the seed low: if the user starts talking on the very first
            // buffer, the floor must still represent quiet, or onset would sit
            // above their voice and speech would never register.
            noiseFloor = Swift.min(level, 0.01)
            hasSeededNoiseFloor = true
            return
        }
        // The floor only follows audio that is quieter than the current
        // estimate quickly; louder audio (speech) barely moves it. This keeps
        // the floor tracking the room, not the speaker.
        if level < noiseFloor {
            noiseFloor = level
        } else {
            noiseFloor += (level - noiseFloor) * configuration.noiseFloorAdaptation * 0.1
        }
    }
}
