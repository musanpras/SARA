import Foundation

/// Relative alert on an event or reminder.
///
/// Stored as an offset rather than an absolute date so it survives the event
/// being moved, which matches EventKit's relative-alarm semantics.
public struct AlertOffset: Hashable, Sendable, Codable {
    /// Seconds before the start date. Always negative or zero.
    public let secondsBeforeStart: TimeInterval

    public init(secondsBeforeStart: TimeInterval) {
        self.secondsBeforeStart = min(0, secondsBeforeStart)
    }

    public static func minutes(_ minutes: Int) -> AlertOffset {
        AlertOffset(secondsBeforeStart: -Double(minutes) * 60)
    }

    public static let atTimeOfEvent = AlertOffset(secondsBeforeStart: 0)

    /// Whole minutes before the start, as a positive number.
    public var minutesBefore: Int {
        Int((-secondsBeforeStart / 60).rounded())
    }
}

/// A calendar event as SARA sees it. Read-only snapshot of EventKit state.
public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public let id: EventIdentifier
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: CalendarIdentifier
    public let calendarTitle: String
    public let location: String?
    public let notes: String?
    public let alerts: [AlertOffset]
    /// True when this event belongs to a recurring series, which changes the
    /// confirmation wording and the delete/update span decision.
    public let isRecurring: Bool

    public init(
        id: EventIdentifier,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarID: CalendarIdentifier,
        calendarTitle: String,
        location: String? = nil,
        notes: String? = nil,
        alerts: [AlertOffset] = [],
        isRecurring: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
        self.alerts = alerts
        self.isRecurring = isRecurring
    }

    public var interval: DateInterval {
        DateInterval(start: start, end: max(start, end))
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Whether this event overlaps `other` in time. Touching edges (one ends
    /// exactly when the next begins) do not count as a conflict.
    public func overlaps(_ other: CalendarEvent) -> Bool {
        start < other.end && other.start < end
    }

    public func overlaps(_ other: DateInterval) -> Bool {
        start < other.end && other.start < end
    }
}

/// Everything needed to create an event. Only fields SARA has actually
/// resolved are present; nothing is invented by the AI layer.
public struct CalendarEventDraft: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: CalendarIdentifier?
    public var location: String?
    public var notes: String?
    public var alerts: [AlertOffset]
    /// Set only when the user asked for a repeating event.
    public var recurrence: RecurrenceRule?

    public init(
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarID: CalendarIdentifier? = nil,
        location: String? = nil,
        notes: String? = nil,
        alerts: [AlertOffset] = [],
        recurrence: RecurrenceRule? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.location = location
        self.notes = notes
        self.alerts = alerts
        self.recurrence = recurrence
    }
}

/// A partial update. `nil` means "leave untouched", which is distinct from
/// clearing a field — clearing uses an explicit empty value.
public struct CalendarEventChanges: Hashable, Sendable, Codable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool?
    public var calendarID: CalendarIdentifier?
    public var location: String?
    public var notes: String?
    public var alerts: [AlertOffset]?

    public init(
        title: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isAllDay: Bool? = nil,
        calendarID: CalendarIdentifier? = nil,
        location: String? = nil,
        notes: String? = nil,
        alerts: [AlertOffset]? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.location = location
        self.notes = notes
        self.alerts = alerts
    }

    public var isEmpty: Bool {
        title == nil && start == nil && end == nil && isAllDay == nil
            && calendarID == nil && location == nil && notes == nil && alerts == nil
    }
}
