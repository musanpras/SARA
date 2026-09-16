import Foundation

/// What the recogniser reports while the user is talking.
public enum SpeechEvent: Sendable {
    /// Text so far. Shown live, never acted on.
    case partialTranscript(String)
    /// The recogniser has settled. This is what enters the pipeline.
    case finalTranscript(text: String, confidence: Double?)
    case failed(SpeechError)
}

public enum SpeechError: Error, Hashable, Sendable {
    case permission(PermissionError)
    case recognizerUnavailable
    case audioEngineFailed(String)
    /// The user held the button but said nothing intelligible.
    case noSpeechDetected
    case underlying(String)
    case unsupportedPlatform

    public var userMessage: String {
        switch self {
        case .permission(let error): error.userMessage
        case .recognizerUnavailable: "Speech recognition isn't available right now."
        case .audioEngineFailed: "I couldn't start the microphone."
        case .noSpeechDetected: "I didn't hear anything."
        case .underlying(let detail): "I couldn't hear that: \(detail)"
        case .unsupportedPlatform: "Voice input isn't available on this device."
        }
    }
}

/// Speech-to-text behind a protocol, so the recogniser can be replaced — and so
/// a wake-word engine can be added in front of it — without touching the UI or
/// the conversation pipeline.
public protocol SpeechRecognizing: Sendable {
    func speechAuthorizationStatus() async -> PermissionStatus
    func microphoneAuthorizationStatus() async -> PermissionStatus
    /// Prompts for whichever of the two is still undetermined.
    func requestAccess() async -> Result<Void, SpeechError>

    /// Begins listening. The stream finishes after a final transcript or a
    /// failure, so a caller always learns how the turn ended.
    func startListening() async -> AsyncStream<SpeechEvent>
    /// Stops the audio and asks for a final result.
    func stopListening() async
    /// Abandons the turn without producing a transcript.
    func cancelListening() async
}

/// Text-to-speech behind a protocol, so SARA's voice is independent of the
/// engine producing it.
public protocol VoiceOutputProvider: Sendable {
    func speak(_ text: String) async
    func stop() async
}

/// Used when speech output is switched off.
public struct SilentVoiceOutputProvider: VoiceOutputProvider {
    public init() {}
    public func speak(_ text: String) async {}
    public func stop() async {}
}
