import Foundation

/// A fully resolved calendar search: real dates, real identifiers.
public struct EventSearchQuery: Hashable, Sendable {
    public var interval: DateInterval
    public var titleContains: String?
    public var calendarIDs: [CalendarIdentifier]?

    public init(interval: DateInterval, titleContains: String? = nil, calendarIDs: [CalendarIdentifier]? = nil) {
        self.interval = interval
        self.titleContains = titleContains
        self.calendarIDs = calendarIDs
    }
}

/// A fully resolved reminder search. A `nil` interval means "regardless of
/// due date", which is how "what do I still need to do?" is expressed.
public struct ReminderSearchQuery: Hashable, Sendable {
    public var interval: DateInterval?
    public var titleContains: String?
    public var listIDs: [CalendarIdentifier]?
    public var completion: ReminderCompletionFilter

    public init(
        interval: DateInterval? = nil,
        titleContains: String? = nil,
        listIDs: [CalendarIdentifier]? = nil,
        completion: ReminderCompletionFilter = .incompleteOnly
    ) {
        self.interval = interval
        self.titleContains = titleContains
        self.listIDs = listIDs
        self.completion = completion
    }
}

/// An operation with every parameter resolved and verified.
///
/// Reaching this type means validation has already happened: dates are real,
/// targets are single records that were confirmed to exist, and permission has
/// been checked. Tools execute these without further interpretation.
public enum ExecutableOperation: Hashable, Sendable {
    case createEvent(CalendarEventDraft)
    case searchEvents(EventSearchQuery)
    /// `target` is the record as it was when validated, which doubles as the
    /// previous state undo needs.
    case updateEvent(target: CalendarEvent, changes: CalendarEventChanges, span: EventSpan)
    case deleteEvent(target: CalendarEvent, span: EventSpan)
    case createReminder(ReminderDraft)
    case searchReminders(ReminderSearchQuery)
    case updateReminder(target: Reminder, changes: ReminderChanges)
    case deleteReminder(target: Reminder)
    case undoLastAction

    public var isDestructive: Bool {
        switch self {
        case .deleteEvent, .deleteReminder: true
        default: false
        }
    }

    public var isReadOnly: Bool {
        switch self {
        case .searchEvents, .searchReminders: true
        default: false
        }
    }
}

public struct ExecutableAction: Hashable, Sendable, Identifiable {
    public let id: ActionID
    public let operation: ExecutableOperation
    public let dependsOn: [ActionID]

    public init(id: ActionID, operation: ExecutableOperation, dependsOn: [ActionID] = []) {
        self.id = id
        self.operation = operation
        self.dependsOn = dependsOn
    }
}

/// A validated plan, ordered into waves that the orchestrator can run.
public struct ExecutablePlan: Hashable, Sendable {
    public let planID: UUID
    public let requestID: UUID
    public let actions: [ExecutableAction]
    /// Actions grouped so each wave may run concurrently and waves run in order.
    public let waves: [[ActionID]]

    public init(planID: UUID, requestID: UUID, actions: [ExecutableAction], waves: [[ActionID]]) {
        self.planID = planID
        self.requestID = requestID
        self.actions = actions
        self.waves = waves
    }

    public func action(withID id: ActionID) -> ExecutableAction? {
        actions.first { $0.id == id }
    }

    public var containsDestructiveAction: Bool {
        actions.contains { $0.operation.isDestructive }
    }
}

/// What validation concluded.
public enum ValidationOutcome: Sendable {
    /// Safe to execute now.
    case ready(ExecutablePlan)
    /// One fact is missing or ambiguous.
    case needsClarification(ClarificationRequest)
    /// Everything resolved, but the user must agree first.
    case needsConfirmation(ConfirmationRequest, ExecutablePlan)
    /// The plan cannot run at all.
    case rejected(ValidationFailure)
}

public extension ExecutableOperation {
    /// A short present-tense phrase describing this work, shown while it runs.
    ///
    /// Names the record wherever one is known, because "Deleting Gym" is
    /// reassuring in a way that "Working" is not — particularly for the
    /// destructive operations the user has just agreed to.
    var progressDescription: String {
        switch self {
        case .createEvent(let draft):
            "Creating \(draft.title)"
        case .updateEvent(let target, _, _):
            "Updating \(target.title)"
        case .deleteEvent(let target, _):
            "Deleting \(target.title)"
        case .createReminder(let draft):
            "Adding \(draft.title)"
        case .updateReminder(let target, _):
            "Updating \(target.title)"
        case .deleteReminder(let target):
            "Deleting \(target.title)"
        case .searchEvents:
            "Checking your calendar"
        case .searchReminders:
            "Checking your reminders"
        case .undoLastAction:
            "Undoing that"
        }
    }
}

public extension ExecutablePlan {
    /// What to show while the plan runs.
    ///
    /// A single action names itself. Several actions are summarised rather than
    /// concatenated, since the label is a status line and not a report.
    var progressDescription: String {
        switch actions.count {
        case 0: "Working"
        case 1: actions[0].operation.progressDescription
        default: "Making \(actions.count) changes"
        }
    }
}
