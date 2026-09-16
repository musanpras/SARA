import Foundation

/// Failures the calendar layer can report. Every case is user-explainable;
/// nothing is swallowed.
public enum CalendarServiceError: Error, Hashable, Sendable {
    case permission(PermissionError)
    /// The referenced event no longer exists — it may have been deleted on
    /// another device between search and execution.
    case eventNotFound(EventIdentifier)
    case calendarNotFound(CalendarIdentifier)
    case calendarIsReadOnly(CalendarIdentifier)
    case noWritableCalendar
    /// EventKit accepted the write but the record could not be read back, so
    /// SARA must not claim success.
    case verificationFailed(String)
    case underlying(String)

    public var userMessage: String {
        switch self {
        case .permission(let error): error.userMessage
        case .eventNotFound: "I couldn't find that event any more — it may have been removed."
        case .calendarNotFound: "I couldn't find that calendar."
        case .calendarIsReadOnly: "That calendar is read-only, so I can't change it."
        case .noWritableCalendar: "There's no calendar I'm allowed to write to."
        case .verificationFailed(let detail): "I couldn't confirm the change went through: \(detail)"
        case .underlying(let detail): "The calendar operation failed: \(detail)"
        }
    }
}

/// Which occurrences of a recurring event an operation applies to.
public enum EventSpan: Hashable, Sendable {
    case thisEvent
    case futureEvents
}

/// The only way SARA touches calendar data.
///
/// Implementations are the sole owners of EventKit. Every mutating call
/// re-reads the record afterwards and returns the stored result, so a caller
/// that receives a value has proof the operation landed.
public protocol CalendarService: Sendable {
    func authorizationStatus() async -> PermissionStatus
    /// Prompts if and only if the status is `.notDetermined`.
    @discardableResult
    func requestAccess() async -> PermissionStatus

    func calendars() async throws -> [CalendarDescriptor]
    func defaultCalendar() async throws -> CalendarDescriptor?

    func events(in interval: DateInterval, calendarIDs: [CalendarIdentifier]?) async throws -> [CalendarEvent]
    func event(id: EventIdentifier) async throws -> CalendarEvent?

    /// Creates the event and returns it as read back from EventKit.
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent
    /// Applies `changes` and returns the event as read back from EventKit.
    func update(id: EventIdentifier, changes: CalendarEventChanges, span: EventSpan) async throws -> CalendarEvent
    /// Deletes the event and verifies it is gone.
    func delete(id: EventIdentifier, span: EventSpan) async throws
}

public extension CalendarService {
    func events(in interval: DateInterval) async throws -> [CalendarEvent] {
        try await events(in: interval, calendarIDs: nil)
    }

    func update(id: EventIdentifier, changes: CalendarEventChanges) async throws -> CalendarEvent {
        try await update(id: id, changes: changes, span: .thisEvent)
    }

    func delete(id: EventIdentifier) async throws {
        try await delete(id: id, span: .thisEvent)
    }
}
