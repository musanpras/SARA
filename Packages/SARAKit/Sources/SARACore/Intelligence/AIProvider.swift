import Foundation

/// What the interpreter is given about the conversation so far.
///
/// Deliberately small: only what is needed to resolve the current utterance.
/// `PrivacyGateway` narrows it further before anything leaves the device.
public struct InterpretationContext: Sendable {
    public var recentTurns: [ConversationMessage]
    /// Set when SARA asked a question and this utterance is the answer.
    public var pendingClarification: ClarificationRequest?
    /// The plan that question was blocking, so an answer updates it rather than
    /// starting over.
    public var pendingPlan: ActionPlan?
    /// Set when SARA asked for confirmation and this utterance is the response.
    public var pendingConfirmation: ConfirmationRequest?
    public var references: ReferenceContext
    public var now: Date

    public init(
        recentTurns: [ConversationMessage] = [],
        pendingClarification: ClarificationRequest? = nil,
        pendingPlan: ActionPlan? = nil,
        pendingConfirmation: ConfirmationRequest? = nil,
        references: ReferenceContext = .empty,
        now: Date
    ) {
        self.recentTurns = recentTurns
        self.pendingClarification = pendingClarification
        self.pendingPlan = pendingPlan
        self.pendingConfirmation = pendingConfirmation
        self.references = references
        self.now = now
    }
}

public struct AIInput: Sendable {
    public let request: UserRequest
    public let context: InterpretationContext

    public init(request: UserRequest, context: InterpretationContext) {
        self.request = request
        self.context = context
    }
}

/// What an interpreter concluded the user wants.
public enum AIResult: Sendable {
    /// Something to validate and possibly execute.
    case plan(ActionPlan)
    /// A question that must be answered before a plan can exist.
    case clarification(ClarificationRequest)
    /// Small talk or an explanation; nothing to execute.
    case conversation(String)
    /// Understood, but outside what SARA can currently do.
    case unsupported(reason: String)
}

public enum AIProviderError: Error, Hashable, Sendable {
    case unavailable(providerID: String)
    case requiresNetwork
    /// The provider answered, but not in a shape SARA can execute.
    case malformedResponse(detail: String)
    case cancelled
    case underlying(String)

    public var userMessage: String {
        switch self {
        case .unavailable:
            "I can't reach my language model right now."
        case .requiresNetwork:
            "That needs an internet connection, and I don't have one."
        case .malformedResponse:
            "I couldn't turn that into something I can safely do."
        case .cancelled:
            "I stopped working on that."
        case .underlying(let detail):
            "Something went wrong while I was thinking: \(detail)."
        }
    }
}

/// What a provider can do, used by the router to pick one deterministically.
public struct ProviderCapabilities: Hashable, Sendable {
    /// Runs entirely on device, so nothing personal leaves the phone.
    public let isOnDevice: Bool
    public let requiresNetwork: Bool
    /// Rough ability to handle open-ended reasoning, 0...1. Used only for
    /// ordering, never as a probability.
    public let reasoningStrength: Double
    /// Relative cost per request; 0 for local.
    public let relativeCost: Double
    /// Typical latency, used to prefer a fast path when quality is equal.
    public let typicalLatency: Duration

    public init(
        isOnDevice: Bool,
        requiresNetwork: Bool,
        reasoningStrength: Double,
        relativeCost: Double,
        typicalLatency: Duration
    ) {
        self.isOnDevice = isOnDevice
        self.requiresNetwork = requiresNetwork
        self.reasoningStrength = reasoningStrength
        self.relativeCost = relativeCost
        self.typicalLatency = typicalLatency
    }
}

/// An interpreter of natural language.
///
/// Providers return SARA's own types and never touch EventKit, so swapping
/// Apple's model for a cloud one changes nothing about how actions execute.
public protocol AIProvider: Sendable {
    var identifier: String { get }
    var capabilities: ProviderCapabilities { get }
    /// Checked before routing; a provider that says no is skipped rather than
    /// tried and failed.
    func isAvailable() async -> Bool
    func interpret(_ input: AIInput) async throws -> AIResult
}
