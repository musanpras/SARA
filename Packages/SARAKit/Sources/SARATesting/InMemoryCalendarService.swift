import Foundation
import SARACore

/// In-memory `CalendarService` used by tests and SwiftUI previews.
///
/// It reproduces the parts of EventKit's behaviour SARA depends on — identity,
/// read-only calendars, permission gating, and read-back verification — so the
/// layers above can be exercised without a real store or a real prompt.
public actor InMemoryCalendarService: CalendarService {
    public private(set) var storedEvents: [EventIdentifier: CalendarEvent] = [:]
    private var storedCalendars: [CalendarDescriptor]
    private var status: PermissionStatus
    private var nextID = 1

    /// When set, the next mutating call throws this instead of succeeding.
    public var failureToInject: CalendarServiceError?
    /// Counts of each operation, for asserting SARA did not act twice.
    public private(set) var createCount = 0
    public private(set) var updateCount = 0
    public private(set) var deleteCount = 0

    public init(
        calendars: [CalendarDescriptor] = [.personal, .work],
        events: [CalendarEvent] = [],
        status: PermissionStatus = .authorized
    ) {
        self.storedCalendars = calendars
        self.status = status
        for event in events { storedEvents[event.id] = event }
    }

    // MARK: - Test control

    public func setStatus(_ status: PermissionStatus) { self.status = status }
    public func setFailure(_ failure: CalendarServiceError?) { failureToInject = failure }
    public func seed(_ events: [CalendarEvent]) {
        for event in events { storedEvents[event.id] = event }
    }
    public var allEvents: [CalendarEvent] {
        storedEvents.values.sorted { $0.start < $1.start }
    }

    // MARK: - CalendarService

    public func authorizationStatus() async -> PermissionStatus { status }

    @discardableResult
    public func requestAccess() async -> PermissionStatus {
        if status == .notDetermined { status = .authorized }
        return status
    }

    private func requireAccess(write: Bool) throws {
        let ok = write ? status.canWrite : status.canRead
        guard ok else {
            throw CalendarServiceError.permission(PermissionError(capability: .calendar, status: status))
        }
    }

    private func takeInjectedFailure() throws {
        if let failure = failureToInject {
            failureToInject = nil
            throw failure
        }
    }

    public func calendars() async throws -> [CalendarDescriptor] {
        try requireAccess(write: false)
        return storedCalendars
    }

    public func defaultCalendar() async throws -> CalendarDescriptor? {
        try requireAccess(write: false)
        return storedCalendars.first(where: \.isDefaultForNewEvents) ?? storedCalendars.first
    }

    public func events(in interval: DateInterval, calendarIDs: [CalendarIdentifier]?) async throws -> [CalendarEvent] {
        try requireAccess(write: false)
        let wanted = calendarIDs.map(Set.init)
        return storedEvents.values
            .filter { $0.overlaps(interval) }
            .filter { wanted == nil || wanted!.contains($0.calendarID) }
            .sorted { $0.start < $1.start }
    }

    public func event(id: EventIdentifier) async throws -> CalendarEvent? {
        try requireAccess(write: false)
        return storedEvents[id]
    }

    public func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try requireAccess(write: true)
        try takeInjectedFailure()

        let calendar = try resolveCalendar(draft.calendarID)
        let id = EventIdentifier("event-\(nextID)")
        nextID += 1

        let event = CalendarEvent(
            id: id,
            title: draft.title,
            start: draft.start,
            end: draft.end,
            isAllDay: draft.isAllDay,
            calendarID: calendar.id,
            calendarTitle: calendar.title,
            location: draft.location,
            notes: draft.notes,
            alerts: draft.alerts,
            isRecurring: draft.recurrence != nil
        )
        storedEvents[id] = event
        createCount += 1
        return event
    }

    public func update(
        id: EventIdentifier,
        changes: CalendarEventChanges,
        span: EventSpan
    ) async throws -> CalendarEvent {
        try requireAccess(write: true)
        try takeInjectedFailure()

        guard let existing = storedEvents[id] else {
            throw CalendarServiceError.eventNotFound(id)
        }
        let calendar = try changes.calendarID.map { try resolveCalendar($0) }

        let updated = CalendarEvent(
            id: id,
            title: changes.title ?? existing.title,
            start: changes.start ?? existing.start,
            end: changes.end ?? existing.end,
            isAllDay: changes.isAllDay ?? existing.isAllDay,
            calendarID: calendar?.id ?? existing.calendarID,
            calendarTitle: calendar?.title ?? existing.calendarTitle,
            location: changes.location ?? existing.location,
            notes: changes.notes ?? existing.notes,
            alerts: changes.alerts ?? existing.alerts,
            isRecurring: existing.isRecurring
        )
        storedEvents[id] = updated
        updateCount += 1
        return updated
    }

    public func delete(id: EventIdentifier, span: EventSpan) async throws {
        try requireAccess(write: true)
        try takeInjectedFailure()

        guard storedEvents[id] != nil else {
            throw CalendarServiceError.eventNotFound(id)
        }
        storedEvents[id] = nil
        deleteCount += 1
    }

    private func resolveCalendar(_ id: CalendarIdentifier?) throws -> CalendarDescriptor {
        if let id {
            guard let match = storedCalendars.first(where: { $0.id == id }) else {
                throw CalendarServiceError.calendarNotFound(id)
            }
            guard match.allowsModification else {
                throw CalendarServiceError.calendarIsReadOnly(id)
            }
            return match
        }
        guard let fallback = storedCalendars.first(where: { $0.isDefaultForNewEvents && $0.allowsModification })
            ?? storedCalendars.first(where: \.allowsModification)
        else {
            throw CalendarServiceError.noWritableCalendar
        }
        return fallback
    }
}

public extension CalendarDescriptor {
    static let personal = CalendarDescriptor(
        id: CalendarIdentifier("cal-personal"),
        title: "Personal",
        sourceTitle: "iCloud",
        allowsModification: true,
        isDefaultForNewEvents: true
    )

    static let work = CalendarDescriptor(
        id: CalendarIdentifier("cal-work"),
        title: "Work",
        sourceTitle: "Exchange",
        allowsModification: true,
        isDefaultForNewEvents: false
    )

    static let holidays = CalendarDescriptor(
        id: CalendarIdentifier("cal-holidays"),
        title: "Holidays",
        sourceTitle: "Subscribed",
        allowsModification: false,
        isDefaultForNewEvents: false
    )
}
