import Foundation

/// A reason a plan cannot run. Every case carries wording SARA can say aloud;
/// nothing fails silently or generically.
public enum ValidationFailure: Error, Hashable, Sendable {
    case unsupportedSchemaVersion(Int)
    case emptyPlan
    case duplicateActionID(ActionID)
    /// Cyclic or dangling dependency edges.
    case invalidDependencyGraph
    case confidenceOutOfRange(Double)
    /// "Delete event" with nothing identifying which event.
    case unconstrainedTarget(ActionType)
    case invalidRecurrence(RecurrenceRule.ValidationFailure)
    case temporal(TemporalError)
    case endsBeforeItStarts
    case nonPositiveDuration(Int)
    /// A search that should have matched something found nothing.
    case targetNotFound(description: String)
    case permission(PermissionError)
    case calendarNotFound(name: String)
    case reminderListNotFound(name: String)
    /// MVP supports reversing one action at a time.
    case unsupportedUndoDepth(Int)
    case nothingToUndo
    /// Every calendar or list is read-only, so nothing can be written anywhere.
    case noWritableContainer

    public var userMessage: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "I couldn't read that plan — it used format version \(version), which I don't support."
        case .emptyPlan:
            "I didn't find anything to do there."
        case .duplicateActionID, .invalidDependencyGraph:
            "I couldn't put those steps in a sensible order, so I haven't done any of them."
        case .confidenceOutOfRange:
            "I wasn't confident enough about that to act on it."
        case .unconstrainedTarget:
            "I need to know which one you mean before I change anything."
        case .invalidRecurrence(let failure):
            failure.userMessage
        case .temporal(let error):
            error.userMessage
        case .endsBeforeItStarts:
            "That would end before it starts."
        case .nonPositiveDuration:
            "An event needs to last longer than zero minutes."
        case .targetNotFound(let description):
            "I couldn't find \(description)."
        case .permission(let error):
            error.userMessage
        case .calendarNotFound(let name):
            "I couldn't find a calendar called \(name)."
        case .reminderListNotFound(let name):
            "I couldn't find a reminders list called \(name)."
        case .unsupportedUndoDepth:
            "I can only undo one thing at a time right now."
        case .nothingToUndo:
            "There's nothing for me to undo."
        case .noWritableContainer:
            "I couldn't find anywhere I'm allowed to save that."
        }
    }
}

/// One choice offered in answer to a clarification question.
public struct ClarificationOption: Hashable, Sendable, Identifiable {
    public let id: String
    /// What the user sees and hears, e.g. "Team Meeting today at 2 PM".
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A single question SARA needs answered before it can continue.
///
/// Exactly one is produced at a time, by design: SARA asks for the next missing
/// fact rather than presenting a form.
public struct ClarificationRequest: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case eventTitle
        case eventDate
        case eventTime
        case reminderTitle
        case reminderDueDate
        /// Several records matched; the user must pick one.
        case whichRecord
        /// Several calendars or lists are plausible.
        case whichContainer
        /// A date phrase has two readings.
        case whichDate
    }

    public let subject: Subject
    public let question: String
    /// Non-empty when the user is picking from candidates.
    public let options: [ClarificationOption]
    /// The action that could not proceed.
    public let actionID: ActionID?
    /// A stable key for *what* is being disambiguated, such as which calendar
    /// the user means by "Home". Set when the answer is worth remembering; a
    /// question about a one-off record leaves it `nil`.
    public let memoryKey: String?

    public init(
        subject: Subject,
        question: String,
        options: [ClarificationOption] = [],
        actionID: ActionID? = nil,
        memoryKey: String? = nil
    ) {
        self.subject = subject
        self.question = question
        self.options = options
        self.actionID = actionID
        self.memoryKey = memoryKey
    }
}

/// A request for explicit agreement before something irreversible or
/// consequential happens.
public struct ConfirmationRequest: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case destructive
        /// The new event overlaps an existing commitment.
        case conflict(existing: [CalendarEvent])
        /// A change that moves an existing commitment.
        case consequentialChange
    }

    public let reason: Reason
    /// What SARA will do, stated plainly enough to agree or refuse.
    public let summary: String
    public let question: String

    public init(reason: Reason, summary: String, question: String) {
        self.reason = reason
        self.summary = summary
        self.question = question
    }
}
