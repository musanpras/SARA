import Foundation

/// Executes validated calendar operations and records how to reverse them.
///
/// It performs no interpretation: by the time an operation reaches this type,
/// dates are resolved, the target is a single verified record, and permission
/// has been checked.
public struct CalendarTool: Sendable {
    private let service: any CalendarService
    private let history: ActionHistory
    private let dateProvider: DateProvider
    private let phrasing: DatePhrasing

    public init(service: any CalendarService, history: ActionHistory, dateProvider: DateProvider) {
        self.service = service
        self.history = history
        self.dateProvider = dateProvider
        self.phrasing = DatePhrasing(calendar: dateProvider.calendar)
    }

    public func execute(_ operation: ExecutableOperation) async throws -> ActionResult {
        switch operation {
        case .createEvent(let draft):
            return try await create(draft)
        case .searchEvents(let query):
            return try await search(query)
        case .updateEvent(let target, let changes, let span):
            return try await update(target: target, changes: changes, span: span)
        case .deleteEvent(let target, let span):
            return try await delete(target: target, span: span)
        default:
            throw ActionFailure(message: "That isn't a calendar operation.")
        }
    }

    private func create(_ draft: CalendarEventDraft) async throws -> ActionResult {
        do {
            let event = try await service.create(draft)
            await history.record(
                HistoryEntry(
                    timestamp: dateProvider.now,
                    summary: "creating \(phrasing.describe(event, relativeTo: dateProvider.now))",
                    reversal: .deleteCreatedEvent(event.id)
                )
            )
            return .createdEvent(event)
        } catch let error as CalendarServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    private func search(_ query: EventSearchQuery) async throws -> ActionResult {
        do {
            var events = try await service.events(in: query.interval, calendarIDs: query.calendarIDs)
            if let fragment = query.titleContains, !fragment.isEmpty {
                events = events.filter { $0.title.localizedCaseInsensitiveContains(fragment) }
            }
            return .foundEvents(events)
        } catch let error as CalendarServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    private func update(
        target: CalendarEvent,
        changes: CalendarEventChanges,
        span: EventSpan
    ) async throws -> ActionResult {
        do {
            let after = try await service.update(id: target.id, changes: changes, span: span)
            await history.record(
                HistoryEntry(
                    timestamp: dateProvider.now,
                    summary: "changing \(phrasing.describe(target, relativeTo: dateProvider.now))",
                    reversal: .restoreEvent(id: after.id, changes: Self.inverse(of: changes, restoring: target))
                )
            )
            return .updatedEvent(before: target, after: after)
        } catch let error as CalendarServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    private func delete(target: CalendarEvent, span: EventSpan) async throws -> ActionResult {
        do {
            try await service.delete(id: target.id, span: span)
            // Intentionally not recorded for undo: re-creating the event would
            // give it a new identity rather than restoring the original.
            return .deletedEvent(target)
        } catch let error as CalendarServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    /// The change set that puts `previous` back, limited to the fields the
    /// original update actually touched.
    static func inverse(
        of changes: CalendarEventChanges,
        restoring previous: CalendarEvent
    ) -> CalendarEventChanges {
        CalendarEventChanges(
            title: changes.title == nil ? nil : previous.title,
            start: changes.start == nil ? nil : previous.start,
            end: changes.end == nil ? nil : previous.end,
            isAllDay: changes.isAllDay == nil ? nil : previous.isAllDay,
            calendarID: changes.calendarID == nil ? nil : previous.calendarID,
            location: changes.location == nil ? nil : (previous.location ?? ""),
            notes: changes.notes == nil ? nil : (previous.notes ?? ""),
            alerts: changes.alerts == nil ? nil : previous.alerts
        )
    }
}
