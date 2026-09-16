import Foundation

/// Everything tunable about hands-free voice, in one place.
///
/// The prompt is explicit that no timing or threshold should be buried inside
/// the audio implementation. Every magic number the voice system would
/// otherwise hard-code lives here, so behaviour can be tuned without touching
/// the engine, the recogniser, or the coordinator.
public struct VoiceConfiguration: Equatable, Sendable {
    /// The phrase that starts a hands-free interaction while the app is open.
    public var wakeWord: String
    /// When false, the microphone only runs during an explicit push-to-talk;
    /// wake-word listening never starts. Kept as a switch so hands-free can be
    /// turned off entirely without removing the machinery.
    public var wakeWordEnabled: Bool
    /// End-of-speech / voice-activity behaviour.
    public var detection: VoiceDetectionConfiguration
    /// A hard ceiling on a single capture, so a stuck recogniser or an open
    /// microphone in a noisy room cannot listen forever.
    public var maximumListeningDuration: TimeInterval

    public init(
        wakeWord: String = "Hey SARA",
        wakeWordEnabled: Bool = true,
        detection: VoiceDetectionConfiguration = .default,
        maximumListeningDuration: TimeInterval = 15
    ) {
        self.wakeWord = wakeWord
        self.wakeWordEnabled = wakeWordEnabled
        self.detection = detection
        self.maximumListeningDuration = maximumListeningDuration
    }

    public static let `default` = VoiceConfiguration()

    /// The options a recogniser needs to end a capture on its own.
    public var endpointing: VoiceEndpointingOptions {
        VoiceEndpointingOptions(detection: detection, maximumDuration: maximumListeningDuration)
    }
}

/// What a recogniser needs in order to stop itself: how to detect end-of-speech,
/// and a hard time limit. Passed per capture so the same recogniser serves both
/// hands-free (endpointed) and manual push-to-talk (the caller stops it).
public struct VoiceEndpointingOptions: Equatable, Sendable {
    public var detection: VoiceDetectionConfiguration
    public var maximumDuration: TimeInterval

    public init(detection: VoiceDetectionConfiguration, maximumDuration: TimeInterval) {
        self.detection = detection
        self.maximumDuration = maximumDuration
    }
}

/// Voice-activity / silence-detection tuning.
///
/// Values are deliberately conservative: cutting a user off mid-sentence is far
/// worse than waiting an extra fraction of a second, so onset is easy and the
/// end-of-speech silence window is generous.
public struct VoiceDetectionConfiguration: Equatable, Sendable {
    /// How long the microphone must stay quiet, after real speech, before the
    /// utterance is considered finished. A natural pause ("schedule a
    /// meeting... tomorrow") is shorter than this, so it does not end the turn.
    public var endOfSpeechSilenceDuration: TimeInterval
    /// The least amount of accumulated speech that counts as an utterance.
    /// Guards against a cough or a door slam ending a turn that never began.
    public var minimumSpeechDuration: TimeInterval
    /// Linear RMS amplitude (0...1) above the estimated noise floor at which a
    /// buffer is treated as the *start* of speech.
    public var onsetThreshold: Float
    /// The lower amplitude at which ongoing speech is treated as having
    /// *stopped*. Kept below `onsetThreshold` on purpose: the gap between the
    /// two is hysteresis, so a voice riding the threshold does not flicker
    /// between speech and silence.
    public var releaseThreshold: Float
    /// How quickly the noise-floor estimate follows the quietest recent audio.
    /// 0 freezes it; 1 makes it track instantly. Small values keep it stable.
    public var noiseFloorAdaptation: Float

    public init(
        endOfSpeechSilenceDuration: TimeInterval = 1.2,
        minimumSpeechDuration: TimeInterval = 0.3,
        onsetThreshold: Float = 0.06,
        releaseThreshold: Float = 0.035,
        noiseFloorAdaptation: Float = 0.05
    ) {
        self.endOfSpeechSilenceDuration = endOfSpeechSilenceDuration
        self.minimumSpeechDuration = minimumSpeechDuration
        self.onsetThreshold = onsetThreshold
        self.releaseThreshold = releaseThreshold
        self.noiseFloorAdaptation = noiseFloorAdaptation
    }

    public static let `default` = VoiceDetectionConfiguration()
}
