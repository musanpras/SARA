import Foundation

/// What an executed operation actually did, as read back from EventKit.
///
/// Every case carries the verified record rather than a boolean, so a response
/// can only describe something that demonstrably exists.
public enum ActionResult: Hashable, Sendable {
    case createdEvent(CalendarEvent)
    case foundEvents([CalendarEvent])
    case updatedEvent(before: CalendarEvent, after: CalendarEvent)
    case deletedEvent(CalendarEvent)
    case createdReminder(Reminder)
    case foundReminders([Reminder])
    case updatedReminder(before: Reminder, after: Reminder)
    case deletedReminder(Reminder)
    /// Describes what was reversed, for the spoken confirmation.
    case undone(summary: String)
}

/// A failure during execution, already phrased for the user.
public struct ActionFailure: Error, Hashable, Sendable {
    public let message: String
    /// True when the action never ran because something it depended on failed.
    public let wasSkipped: Bool

    public init(message: String, wasSkipped: Bool = false) {
        self.message = message
        self.wasSkipped = wasSkipped
    }

    static func skipped(because reason: String) -> ActionFailure {
        ActionFailure(message: reason, wasSkipped: true)
    }
}

/// The outcome of every action in a plan.
///
/// Partial success is a first-class state: SARA reports exactly which steps
/// worked and which did not, and never rounds a mixed result up to "done".
public struct ExecutionReport: Sendable {
    public struct Entry: Sendable {
        public let id: ActionID
        public let result: Result<ActionResult, ActionFailure>

        public init(id: ActionID, result: Result<ActionResult, ActionFailure>) {
            self.id = id
            self.result = result
        }

        public var succeeded: Bool {
            if case .success = result { return true }
            return false
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var successes: [ActionResult] {
        entries.compactMap { entry in
            guard case .success(let value) = entry.result else { return nil }
            return value
        }
    }

    public var failures: [ActionFailure] {
        entries.compactMap { entry in
            guard case .failure(let error) = entry.result else { return nil }
            return error
        }
    }

    public var allSucceeded: Bool { !entries.isEmpty && failures.isEmpty }
    public var allFailed: Bool { !entries.isEmpty && entries.allSatisfy { !$0.succeeded } }
    public var isPartialSuccess: Bool { !failures.isEmpty && failures.count < entries.count }

    public func result(for id: ActionID) -> Result<ActionResult, ActionFailure>? {
        entries.first { $0.id == id }?.result
    }
}
