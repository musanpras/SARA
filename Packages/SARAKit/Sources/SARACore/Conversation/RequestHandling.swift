import Foundation

/// Where an utterance came from. Voice and text converge here and are treated
/// identically from this point on, per the single-pipeline requirement.
public enum InputSource: Equatable, Sendable {
    case voice
    case text
}

/// A normalised user utterance entering SARA Core.
public struct UserRequest: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let source: InputSource
    /// Speech recogniser confidence, when the source can report one.
    public let transcriptionConfidence: Double?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        text: String,
        source: InputSource,
        transcriptionConfidence: Double? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.transcriptionConfidence = transcriptionConfidence
        self.timestamp = timestamp
    }

    /// Trimmed text with collapsed whitespace, as seen by the rest of the pipeline.
    public var normalizedText: String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// The outcome of one turn: what SARA now says, and what state it settles into.
public struct AssistantTurn: Equatable, Sendable {
    public let messages: [ConversationMessage]
    public let state: AssistantState

    public init(messages: [ConversationMessage], state: AssistantState) {
        self.messages = messages
        self.state = state
    }
}

/// The single entry point into SARA Core.
///
/// The presentation layer knows only this protocol, so the full pipeline
/// (context, intelligence, validation, tools, verification) can be built behind
/// it without touching any view.
public protocol RequestHandling: Sendable {
    func handle(_ request: UserRequest) async -> AssistantTurn

    /// Handles a request, reporting when execution starts.
    ///
    /// Defaulted, so a handler that has no distinct execution phase — a stub, or
    /// a future handler that only ever answers — conforms without implementing
    /// it.
    func handle(_ request: UserRequest, progress: (any TurnProgressObserving)?) async -> AssistantTurn
}

public extension RequestHandling {
    func handle(
        _ request: UserRequest,
        progress: (any TurnProgressObserving)?
    ) async -> AssistantTurn {
        await handle(request)
    }
}
