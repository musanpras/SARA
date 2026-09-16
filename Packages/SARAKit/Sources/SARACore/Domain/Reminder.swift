import Foundation

/// A reminders list, described without EventKit types.
public struct ReminderListDescriptor: Identifiable, Hashable, Sendable {
    public let id: CalendarIdentifier
    public let title: String
    public let sourceTitle: String
    public let allowsModification: Bool
    public let isDefaultForNewReminders: Bool

    public init(
        id: CalendarIdentifier,
        title: String,
        sourceTitle: String,
        allowsModification: Bool,
        isDefaultForNewReminders: Bool
    ) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.allowsModification = allowsModification
        self.isDefaultForNewReminders = isDefaultForNewReminders
    }
}

/// A reminder as SARA sees it.
///
/// `dueDate` is the resolved moment the reminder is due; `hasTimeComponent`
/// records whether the user actually specified a time, because a date-only
/// reminder must not be reported back as if it had one.
public struct Reminder: Identifiable, Hashable, Sendable {
    public let id: ReminderIdentifier
    public let title: String
    public let dueDate: Date?
    public let hasTimeComponent: Bool
    public let isCompleted: Bool
    public let completionDate: Date?
    public let listID: CalendarIdentifier
    public let listTitle: String
    public let notes: String?
    public let alerts: [AlertOffset]

    public init(
        id: ReminderIdentifier,
        title: String,
        dueDate: Date? = nil,
        hasTimeComponent: Bool = false,
        isCompleted: Bool = false,
        completionDate: Date? = nil,
        listID: CalendarIdentifier,
        listTitle: String,
        notes: String? = nil,
        alerts: [AlertOffset] = []
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.hasTimeComponent = hasTimeComponent
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.listID = listID
        self.listTitle = listTitle
        self.notes = notes
        self.alerts = alerts
    }
}

public struct ReminderDraft: Hashable, Sendable {
    public var title: String
    public var dueDate: Date?
    /// False for "remind me tomorrow" with no stated time, true for an explicit
    /// or defaulted clock time.
    public var hasTimeComponent: Bool
    public var listID: CalendarIdentifier?
    public var notes: String?
    public var alerts: [AlertOffset]

    public init(
        title: String,
        dueDate: Date? = nil,
        hasTimeComponent: Bool = true,
        listID: CalendarIdentifier? = nil,
        notes: String? = nil,
        alerts: [AlertOffset] = []
    ) {
        self.title = title
        self.dueDate = dueDate
        self.hasTimeComponent = hasTimeComponent
        self.listID = listID
        self.notes = notes
        self.alerts = alerts
    }
}

/// A partial reminder update. `nil` leaves a field untouched.
///
/// `clearDueDate` exists because `dueDate: nil` already means "no change";
/// removing a due date has to be asked for explicitly.
public struct ReminderChanges: Hashable, Sendable, Codable {
    public var title: String?
    public var dueDate: Date?
    public var hasTimeComponent: Bool?
    public var clearDueDate: Bool
    public var isCompleted: Bool?
    public var listID: CalendarIdentifier?
    public var notes: String?
    public var alerts: [AlertOffset]?

    public init(
        title: String? = nil,
        dueDate: Date? = nil,
        hasTimeComponent: Bool? = nil,
        clearDueDate: Bool = false,
        isCompleted: Bool? = nil,
        listID: CalendarIdentifier? = nil,
        notes: String? = nil,
        alerts: [AlertOffset]? = nil
    ) {
        self.title = title
        self.dueDate = dueDate
        self.hasTimeComponent = hasTimeComponent
        self.clearDueDate = clearDueDate
        self.isCompleted = isCompleted
        self.listID = listID
        self.notes = notes
        self.alerts = alerts
    }

    public var isEmpty: Bool {
        title == nil && dueDate == nil && hasTimeComponent == nil && !clearDueDate
            && isCompleted == nil && listID == nil && notes == nil && alerts == nil
    }
}

/// Which reminders a search should return.
public enum ReminderCompletionFilter: Hashable, Sendable {
    case incompleteOnly
    case completedOnly
    case all
}
