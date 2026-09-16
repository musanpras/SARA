import EventKit
import Foundation
import SARACore

/// EventKit-backed calendar access.
///
/// An actor because `EKEventStore` is not thread-safe and every mutation must
/// be serialised against the reads that verify it. EventKit remains the source
/// of truth: nothing here caches events.
public actor EventKitCalendarService: CalendarService {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: - Authorization

    public func authorizationStatus() async -> PermissionStatus {
        EventKitMapping.permissionStatus(EKEventStore.authorizationStatus(for: .event))
    }

    @discardableResult
    public func requestAccess() async -> PermissionStatus {
        let current = await authorizationStatus()
        guard current.isPromptable else { return current }

        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // A thrown error here means the prompt failed, not that access was
            // granted; re-reading the status below reports the truth either way.
        }
        return await authorizationStatus()
    }

    /// Fails fast with an explainable error when the needed access is absent.
    private func requireAccess(write: Bool) async throws {
        let status = await authorizationStatus()
        let ok = write ? status.canWrite : status.canRead
        guard ok else {
            throw CalendarServiceError.permission(
                PermissionError(capability: .calendar, status: status)
            )
        }
    }

    // MARK: - Calendars

    public func calendars() async throws -> [CalendarDescriptor] {
        try await requireAccess(write: false)
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event)
            .map { EventKitMapping.descriptor($0, defaultCalendarID: defaultID) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func defaultCalendar() async throws -> CalendarDescriptor? {
        try await requireAccess(write: false)
        guard let calendar = store.defaultCalendarForNewEvents else { return nil }
        return EventKitMapping.descriptor(calendar, defaultCalendarID: calendar.calendarIdentifier)
    }

    // MARK: - Reads

    public func events(in interval: DateInterval, calendarIDs: [CalendarIdentifier]?) async throws -> [CalendarEvent] {
        try await requireAccess(write: false)

        let calendars: [EKCalendar]?
        if let calendarIDs {
            let wanted = Set(calendarIDs.map(\.rawValue))
            calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        } else {
            calendars = nil
        }

        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars
        )
        return store.events(matching: predicate)
            .compactMap(EventKitMapping.event)
            .sorted { $0.start < $1.start }
    }

    public func event(id: EventIdentifier) async throws -> CalendarEvent? {
        try await requireAccess(write: false)
        guard let event = store.event(withIdentifier: id.rawValue) else { return nil }
        return EventKitMapping.event(event)
    }

    // MARK: - Writes

    public func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await requireAccess(write: true)

        let calendar = try resolveCalendar(draft.calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        event.alarms = EventKitMapping.alarms(for: draft.alerts)
        if let recurrence = draft.recurrence {
            event.recurrenceRules = [EventKitMapping.recurrenceRule(recurrence)]
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.underlying(error.localizedDescription)
        }

        return try verifyExists(event.eventIdentifier, context: "the new event")
    }

    public func update(
        id: EventIdentifier,
        changes: CalendarEventChanges,
        span: EventSpan
    ) async throws -> CalendarEvent {
        try await requireAccess(write: true)

        guard let event = store.event(withIdentifier: id.rawValue) else {
            throw CalendarServiceError.eventNotFound(id)
        }
        if let calendar = event.calendar, !calendar.allowsContentModifications {
            throw CalendarServiceError.calendarIsReadOnly(CalendarIdentifier(calendar.calendarIdentifier))
        }

        if let title = changes.title { event.title = title }
        if let start = changes.start { event.startDate = start }
        if let end = changes.end { event.endDate = end }
        if let isAllDay = changes.isAllDay { event.isAllDay = isAllDay }
        if let location = changes.location { event.location = location }
        if let notes = changes.notes { event.notes = notes }
        if let alerts = changes.alerts { event.alarms = EventKitMapping.alarms(for: alerts) }
        if let calendarID = changes.calendarID {
            event.calendar = try resolveCalendar(calendarID)
        }

        do {
            try store.save(event, span: EventKitMapping.span(span), commit: true)
        } catch {
            throw CalendarServiceError.underlying(error.localizedDescription)
        }

        // Moving an event between calendars can mint a new identifier, so the
        // post-save identifier is read from the object rather than the request.
        return try verifyExists(event.eventIdentifier, context: "the updated event")
    }

    public func delete(id: EventIdentifier, span: EventSpan) async throws {
        try await requireAccess(write: true)

        guard let event = store.event(withIdentifier: id.rawValue) else {
            throw CalendarServiceError.eventNotFound(id)
        }
        if let calendar = event.calendar, !calendar.allowsContentModifications {
            throw CalendarServiceError.calendarIsReadOnly(CalendarIdentifier(calendar.calendarIdentifier))
        }

        do {
            try store.remove(event, span: EventKitMapping.span(span), commit: true)
        } catch {
            throw CalendarServiceError.underlying(error.localizedDescription)
        }

        // Only a recurring series deleted with `.thisEvent` may legitimately
        // still resolve; a single event that survives means the delete failed.
        if span == .thisEvent, !event.hasRecurrenceRules,
           store.event(withIdentifier: id.rawValue) != nil {
            throw CalendarServiceError.verificationFailed("the event is still in your calendar")
        }
    }

    // MARK: - Helpers

    private func resolveCalendar(_ id: CalendarIdentifier?) throws -> EKCalendar {
        if let id {
            guard let calendar = store.calendar(withIdentifier: id.rawValue) else {
                throw CalendarServiceError.calendarNotFound(id)
            }
            guard calendar.allowsContentModifications else {
                throw CalendarServiceError.calendarIsReadOnly(id)
            }
            return calendar
        }

        guard let fallback = store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: \.allowsContentModifications)
        else {
            throw CalendarServiceError.noWritableCalendar
        }
        return fallback
    }

    /// Re-reads a just-written event so success is proven, not assumed.
    private func verifyExists(_ identifier: String?, context: String) throws -> CalendarEvent {
        guard let identifier, !identifier.isEmpty else {
            throw CalendarServiceError.verificationFailed("\(context) has no identifier")
        }
        guard let saved = store.event(withIdentifier: identifier),
              let mapped = EventKitMapping.event(saved)
        else {
            throw CalendarServiceError.verificationFailed("I couldn't read back \(context)")
        }
        return mapped
    }
}
