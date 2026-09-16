import Foundation

/// The single visible state of the assistant.
///
/// The UI renders one state at a time so the user perceives one assistant
/// rather than a set of cooperating subsystems. Transitions are constrained so
/// an illegal sequence (for example `.idle -> .executing`) is caught in tests
/// rather than shipping as a confusing animation.
public enum AssistantState: Equatable, Sendable {
    case idle
    case listening
    case processing
    /// SARA needs one more fact before it can build a plan.
    case clarifying(question: String)
    /// SARA has a validated plan but the action is destructive or consequential.
    case confirming(summary: String)
    case executing(description: String)
    case success(message: String)
    case failed(message: String)

    /// True while SARA is doing work the user should wait for.
    public var isBusy: Bool {
        switch self {
        case .processing, .executing: true
        case .idle, .listening, .clarifying, .confirming, .success, .failed: false
        }
    }

    /// True while SARA is waiting on the user rather than on itself.
    public var awaitsUser: Bool {
        switch self {
        case .clarifying, .confirming: true
        default: false
        }
    }

    /// True when a new user utterance may be accepted.
    /// Exhaustive on purpose: a new state must decide whether it accepts
    /// input, because the transition rules below are written in terms of it.
    public var acceptsInput: Bool {
        switch self {
        case .processing, .executing, .listening: false
        case .idle, .clarifying, .confirming, .success, .failed: true
        }
    }

    /// Case tests that ignore associated values, so transition rules can be
    /// written without repeating every payload.
    public var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    public var isExecuting: Bool {
        if case .executing = self { return true }
        return false
    }

    public var isConfirming: Bool {
        if case .confirming = self { return true }
        return false
    }

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

public extension AssistantState {
    /// Whether moving to `next` is a legal transition.
    ///
    /// Expressed as rules about the destination rather than a list of allowed
    /// pairs. The pair list was easy to read but easy to leave incomplete, and
    /// a missing pair is not a harmless omission: it crashes debug builds and
    /// silently strands the UI mid-turn in release builds. The rules below say
    /// what each state actually requires, so a legitimate flow cannot be
    /// forgotten.
    func canTransition(to next: AssistantState) -> Bool {
        switch next {
        case .failed:
            // Any stage can report an explicit failure.
            return true

        case .listening:
            // The microphone may be used whenever SARA is not mid-turn, which
            // includes while it is waiting on an answer — speaking the reply to
            // a question is the natural thing to do.
            return acceptsInput

        case .processing:
            // A new utterance can be interpreted from any state that accepts
            // input, and from `.listening` once a transcript arrives.
            return acceptsInput || isListening

        case .clarifying, .confirming:
            // Questions only come out of interpreting a request.
            return isProcessing

        case .executing:
            // Work starts either straight after validation or once the user has
            // agreed to it. It can never be reached from rest.
            return isProcessing || isConfirming

        case .success:
            // Success is only claimed after work that actually ran.
            return isProcessing || isExecuting

        case .idle:
            // A turn can legitimately end with nothing pending and nothing
            // done: a declined action, small talk, or an abandoned voice
            // capture. Execution is the one thing that must resolve to an
            // explicit outcome rather than quietly returning to rest.
            return !isExecuting
        }
    }
}
