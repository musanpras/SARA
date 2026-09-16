import Foundation

/// The microphone's role in a hands-free session.
///
/// This is intentionally *not* a second copy of `AssistantState`. `AssistantState`
/// says what SARA is doing in the conversation (thinking, confirming, executing);
/// `VoiceSessionMode` says what the microphone is doing right now. Together they
/// are the authoritative description of the voice lifecycle, and mic behaviour is
/// derived from them rather than from scattered `isListening` / `shouldListen`
/// booleans.
///
/// The states map onto the lifecycle the prompt sketches:
/// `off` — hands-free disabled (manual push-to-talk only);
/// `idle` — hands-free on but between interactions;
/// `waitingForWakeWord` — the wake engine is listening;
/// `capturingCommand` — recording the user, VAD deciding end-of-speech;
/// `processing` — the pipeline is running, microphone released;
/// `speaking` — SARA is talking, microphone released so it never hears itself;
/// `waitingForFollowUp` — SARA asked a question and is about to re-open the mic.
public enum VoiceSessionMode: Equatable, Sendable {
    case off
    case idle
    case waitingForWakeWord
    case capturingCommand
    case processing
    case speaking
    case waitingForFollowUp

    /// True while the microphone is (or is about to be) capturing the user for a
    /// command or an answer — the states in which SARA must not also be
    /// listening for the wake word or playing audio.
    public var isCapturing: Bool {
        self == .capturingCommand
    }

    /// True while hands-free is engaged at all.
    public var isActive: Bool {
        self != .off
    }
}

/// Decides what happens to the microphone after a conversational turn settles.
///
/// Pure and free of AVFoundation so the "does SARA re-open the mic?" question is
/// answered by the conversation's outcome alone, and can be tested directly.
/// This is the rule behind automatic follow-up listening: when SARA still needs
/// the user, it listens again without a button press; otherwise it returns to
/// waiting for the wake word.
public struct VoiceInteractionPolicy: Sendable {
    public enum FollowUp: Equatable, Sendable {
        /// SARA asked something (a clarification or a confirmation): re-open the
        /// microphone automatically once it has finished speaking.
        case listenAgain
        /// The turn is complete (or failed): go back to waiting for the wake
        /// word.
        case returnToWakeWord
    }

    public init() {}

    /// The follow-up action implied by the state a turn ended in.
    public func followUp(after state: AssistantState) -> FollowUp {
        switch state {
        case .clarifying, .confirming:
            return .listenAgain
        case .idle, .listening, .processing, .executing, .success, .failed:
            return .returnToWakeWord
        }
    }
}
