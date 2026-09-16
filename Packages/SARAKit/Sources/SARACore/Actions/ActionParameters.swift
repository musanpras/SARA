import Foundation

/// Parameters for `calendar.create`.
///
/// Only `title` and `when` are required; everything else is either inferred by
/// Swift from preferences or asked about. The model never fills these in with
/// plausible-sounding invented values.
public struct CalendarCreateParameters: Hashable, Sendable, Codable {
    /// Empty when the user never said what the event is called; SARA asks
    /// rather than inventing a title.
    public var title: String
    /// Absent when the user gave no date at all.
    public var when: DateTimeSpec?
    /// Explicit duration. When absent, the configured default applies.
    public var durationMinutes: Int?
    public var isAllDay: Bool
    /// Calendar as the user named it; resolved to an identifier during validation.
    public var calendarName: String?
    /// An already-resolved calendar, set when the user picked one from a list.
    /// Takes precedence over `calendarName`, which may still be ambiguous.
    public var calendarID: String?
    /// Minutes before the start, e.g. `[30]` for "remind me 30 minutes before".
    public var alertMinutesBefore: [Int]
    public var recurrence: RecurrenceRule?
    public var location: String?
    public var notes: String?

    public init(
        title: String,
        when: DateTimeSpec? = nil,
        durationMinutes: Int? = nil,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        calendarID: String? = nil,
        alertMinutesBefore: [Int] = [],
        recurrence: RecurrenceRule? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.when = when
        self.durationMinutes = durationMinutes
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.calendarID = calendarID
        self.alertMinutesBefore = alertMinutesBefore
        self.recurrence = recurrence
        self.location = location
        self.notes = notes
    }
}

/// Parameters for `reminder.create`.
public struct ReminderCreateParameters: Hashable, Sendable, Codable {
    public var title: String
    /// Absent when the user gave no due date at all; a reminder may legitimately
    /// have none, so this is not automatically a missing-information error.
    public var due: DateTimeSpec?
    public var listName: String?
    /// An already-resolved list, set when the user picked one from a list.
    public var listID: String?
    public var alertMinutesBefore: [Int]
    public var notes: String?

    public init(
        title: String,
        due: DateTimeSpec? = nil,
        listName: String? = nil,
        listID: String? = nil,
        alertMinutesBefore: [Int] = [],
        notes: String? = nil
    ) {
        self.title = title
        self.due = due
        self.listName = listName
        self.listID = listID
        self.alertMinutesBefore = alertMinutesBefore
        self.notes = notes
    }
}

/// The fields an update may change. A `nil` means "leave alone".
public struct EventChangeSpec: Hashable, Sendable, Codable {
    public var title: String?
    public var when: DateTimeSpec?
    public var durationMinutes: Int?
    public var calendarName: String?
    /// An already-resolved calendar, set when the user picked one from a list.
    public var calendarID: String?
    public var alertMinutesBefore: [Int]?
    public var location: String?
    public var notes: String?

    public init(
        title: String? = nil,
        when: DateTimeSpec? = nil,
        durationMinutes: Int? = nil,
        calendarName: String? = nil,
        calendarID: String? = nil,
        alertMinutesBefore: [Int]? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.when = when
        self.durationMinutes = durationMinutes
        self.calendarName = calendarName
        self.calendarID = calendarID
        self.alertMinutesBefore = alertMinutesBefore
        self.location = location
        self.notes = notes
    }

    public var isEmpty: Bool {
        title == nil && when == nil && durationMinutes == nil && calendarName == nil
            && calendarID == nil && alertMinutesBefore == nil && location == nil && notes == nil
    }

    /// Changes a user would want confirmed because they move a commitment.
    public var isConsequential: Bool {
        when != nil || calendarName != nil || calendarID != nil
    }
}

public struct ReminderChangeSpec: Hashable, Sendable, Codable {
    public var title: String?
    public var due: DateTimeSpec?
    public var clearDue: Bool
    public var markCompleted: Bool?
    public var listName: String?
    /// An already-resolved list, set when the user picked one from a list.
    public var listID: String?
    public var alertMinutesBefore: [Int]?
    public var notes: String?

    public init(
        title: String? = nil,
        due: DateTimeSpec? = nil,
        clearDue: Bool = false,
        markCompleted: Bool? = nil,
        listName: String? = nil,
        listID: String? = nil,
        alertMinutesBefore: [Int]? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.due = due
        self.clearDue = clearDue
        self.markCompleted = markCompleted
        self.listName = listName
        self.listID = listID
        self.alertMinutesBefore = alertMinutesBefore
        self.notes = notes
    }

    public var isEmpty: Bool {
        title == nil && due == nil && !clearDue && markCompleted == nil
            && listName == nil && listID == nil && alertMinutesBefore == nil && notes == nil
    }
}

public struct UpdateParameters<Changes: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public var target: EntityQuery
    public var changes: Changes

    public init(target: EntityQuery, changes: Changes) {
        self.target = target
        self.changes = changes
    }
}

public struct DeleteParameters: Hashable, Sendable, Codable {
    public var target: EntityQuery
    /// For a recurring series: just this occurrence, or all future ones.
    public var includeFutureOccurrences: Bool

    public init(target: EntityQuery, includeFutureOccurrences: Bool = false) {
        self.target = target
        self.includeFutureOccurrences = includeFutureOccurrences
    }
}

public struct SearchParameters: Hashable, Sendable, Codable {
    public var query: EntityQuery

    public init(query: EntityQuery) {
        self.query = query
    }
}

public struct UndoParameters: Hashable, Sendable, Codable {
    /// How many recorded actions to reverse. MVP only supports one.
    public var steps: Int

    public init(steps: Int = 1) {
        self.steps = steps
    }
}
