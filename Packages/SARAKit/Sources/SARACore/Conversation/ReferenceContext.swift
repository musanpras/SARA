import Foundation

/// What "it", "that" and "the second one" currently point at.
///
/// Held by the conversation layer and handed to validation. Resolution is
/// deterministic Swift: a pronoun is turned into a concrete record here, or
/// SARA asks. It is never passed to a tool unresolved.
public struct ReferenceContext: Hashable, Sendable {
    /// Events SARA last read out, in the order it presented them.
    public var presentedEvents: [CalendarEvent]
    /// Reminders SARA last read out, in the order it presented them.
    public var presentedReminders: [Reminder]
    /// The event SARA most recently created or changed.
    public var lastTouchedEvent: CalendarEvent?
    /// The reminder SARA most recently created or changed.
    public var lastTouchedReminder: Reminder?

    public init(
        presentedEvents: [CalendarEvent] = [],
        presentedReminders: [Reminder] = [],
        lastTouchedEvent: CalendarEvent? = nil,
        lastTouchedReminder: Reminder? = nil
    ) {
        self.presentedEvents = presentedEvents
        self.presentedReminders = presentedReminders
        self.lastTouchedEvent = lastTouchedEvent
        self.lastTouchedReminder = lastTouchedReminder
    }

    public static let empty = ReferenceContext()

    /// The combined list the user saw, used to resolve "the second one" across
    /// a mixed events-and-reminders answer.
    public var presentedItemCount: Int {
        presentedEvents.count + presentedReminders.count
    }

    public mutating func present(events: [CalendarEvent], reminders: [Reminder]) {
        presentedEvents = events
        presentedReminders = reminders
    }

    public mutating func recordTouch(event: CalendarEvent) {
        lastTouchedEvent = event
    }

    public mutating func recordTouch(reminder: Reminder) {
        lastTouchedReminder = reminder
    }
}
