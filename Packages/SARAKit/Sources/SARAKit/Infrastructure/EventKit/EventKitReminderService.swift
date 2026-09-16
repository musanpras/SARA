import EventKit
import Foundation
import SARACore

/// EventKit-backed reminder access.
///
/// Mirrors `EventKitCalendarService`: an actor around a single `EKEventStore`,
/// with every write verified by a read-back before it is reported as done.
public actor EventKitReminderService: ReminderService {
    private let store: EKEventStore
    private let calendar: Calendar

    public init(store: EKEventStore = EKEventStore(), calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.calendar = calendar
    }

    // MARK: - Authorization

    public func authorizationStatus() async -> PermissionStatus {
        EventKitMapping.permissionStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    @discardableResult
    public func requestAccess() async -> PermissionStatus {
        let current = await authorizationStatus()
        guard current.isPromptable else { return current }
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            // Status is re-read below; a thrown prompt error never implies access.
        }
        return await authorizationStatus()
    }

    private func requireAccess(write: Bool) async throws {
        let status = await authorizationStatus()
        let ok = write ? status.canWrite : status.canRead
        guard ok else {
            throw ReminderServiceError.permission(
                PermissionError(capability: .reminders, status: status)
            )
        }
    }

    // MARK: - Lists

    public func lists() async throws -> [ReminderListDescriptor] {
        try await requireAccess(write: false)
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder)
            .map { list in
                ReminderListDescriptor(
                    id: CalendarIdentifier(list.calendarIdentifier),
                    title: list.title,
                    sourceTitle: list.source?.title ?? "",
                    allowsModification: list.allowsContentModifications,
                    isDefaultForNewReminders: list.calendarIdentifier == defaultID
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func defaultList() async throws -> ReminderListDescriptor? {
        try await requireAccess(write: false)
        guard let list = store.defaultCalendarForNewReminders() else { return nil }
        return ReminderListDescriptor(
            id: CalendarIdentifier(list.calendarIdentifier),
            title: list.title,
            sourceTitle: list.source?.title ?? "",
            allowsModification: list.allowsContentModifications,
            isDefaultForNewReminders: true
        )
    }

    // MARK: - Reads

    public func reminders(
        dueIn interval: DateInterval?,
        listIDs: [CalendarIdentifier]?,
        filter: ReminderCompletionFilter
    ) async throws -> [Reminder] {
        try await requireAccess(write: false)

        let lists = resolveLists(listIDs)
        let predicate: NSPredicate
        switch (filter, interval) {
        case (.incompleteOnly, let interval):
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: interval?.start,
                ending: interval?.end,
                calendars: lists
            )
        case (.completedOnly, let interval):
            predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: interval?.start,
                ending: interval?.end,
                calendars: lists
            )
        case (.all, _):
            predicate = store.predicateForReminders(in: lists)
        }

        var results = try await fetch(predicate)

        // `predicateForReminders(in:)` ignores dates, so an interval filter for
        // `.all` is applied here rather than silently dropped.
        if filter == .all, let interval {
            results = results.filter { reminder in
                guard let due = reminder.dueDate else { return false }
                return interval.contains(due)
            }
        }

        return results.sorted(by: Self.dueDateOrder)
    }

    public func reminder(id: ReminderIdentifier) async throws -> Reminder? {
        try await requireAccess(write: false)
        guard let item = store.calendarItem(withIdentifier: id.rawValue) as? EKReminder else {
            return nil
        }
        return map(item)
    }

    // MARK: - Writes

    public func create(_ draft: ReminderDraft) async throws -> Reminder {
        try await requireAccess(write: true)

        let list = try resolveList(draft.listID)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.alarms = EventKitMapping.alarms(for: draft.alerts)
        applyDueDate(draft.dueDate, hasTime: draft.hasTimeComponent, to: reminder)

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.underlying(error.localizedDescription)
        }

        return try verifyExists(reminder.calendarItemIdentifier, context: "the new reminder")
    }

    public func update(id: ReminderIdentifier, changes: ReminderChanges) async throws -> Reminder {
        try await requireAccess(write: true)

        guard let reminder = store.calendarItem(withIdentifier: id.rawValue) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }
        if let list = reminder.calendar, !list.allowsContentModifications {
            throw ReminderServiceError.listIsReadOnly(CalendarIdentifier(list.calendarIdentifier))
        }

        if let title = changes.title { reminder.title = title }
        if let notes = changes.notes { reminder.notes = notes }
        if let alerts = changes.alerts { reminder.alarms = EventKitMapping.alarms(for: alerts) }
        if let isCompleted = changes.isCompleted { reminder.isCompleted = isCompleted }
        if let listID = changes.listID { reminder.calendar = try resolveList(listID) }

        if changes.clearDueDate {
            reminder.dueDateComponents = nil
        } else if let dueDate = changes.dueDate {
            let hasTime = changes.hasTimeComponent
                ?? (reminder.dueDateComponents?.hour != nil)
            applyDueDate(dueDate, hasTime: hasTime, to: reminder)
        } else if let hasTime = changes.hasTimeComponent,
                  let existing = existingDueDate(reminder) {
            applyDueDate(existing, hasTime: hasTime, to: reminder)
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw ReminderServiceError.underlying(error.localizedDescription)
        }

        return try verifyExists(reminder.calendarItemIdentifier, context: "the updated reminder")
    }

    public func delete(id: ReminderIdentifier) async throws {
        try await requireAccess(write: true)

        guard let reminder = store.calendarItem(withIdentifier: id.rawValue) as? EKReminder else {
            throw ReminderServiceError.reminderNotFound(id)
        }
        if let list = reminder.calendar, !list.allowsContentModifications {
            throw ReminderServiceError.listIsReadOnly(CalendarIdentifier(list.calendarIdentifier))
        }

        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw ReminderServiceError.underlying(error.localizedDescription)
        }

        if store.calendarItem(withIdentifier: id.rawValue) != nil {
            throw ReminderServiceError.verificationFailed("the reminder is still in your list")
        }
    }

    // MARK: - Helpers

    /// Bridges EventKit's completion-handler fetch into structured concurrency.
    ///
    /// The callback runs off the actor, so `EKReminder` objects are mapped to
    /// value types inside it — only Sendable results cross back.
    private func fetch(_ predicate: NSPredicate) async throws -> [Reminder] {
        let calendar = self.calendar
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).compactMap { Self.map($0, calendar: calendar) }
                continuation.resume(returning: mapped)
            }
        }
    }

    private func resolveLists(_ ids: [CalendarIdentifier]?) -> [EKCalendar]? {
        guard let ids else { return nil }
        let wanted = Set(ids.map(\.rawValue))
        let matches = store.calendars(for: .reminder).filter { wanted.contains($0.calendarIdentifier) }
        return matches.isEmpty ? nil : matches
    }

    private func resolveList(_ id: CalendarIdentifier?) throws -> EKCalendar {
        if let id {
            guard let list = store.calendar(withIdentifier: id.rawValue) else {
                throw ReminderServiceError.listNotFound(id)
            }
            guard list.allowsContentModifications else {
                throw ReminderServiceError.listIsReadOnly(id)
            }
            return list
        }

        guard let fallback = store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first(where: \.allowsContentModifications)
        else {
            throw ReminderServiceError.noWritableList
        }
        return fallback
    }

    /// Writes a due date as date-only or date-and-time components.
    ///
    /// EventKit treats the presence of an hour component as "this reminder has
    /// a time", and only timed reminders can fire an alert, so the distinction
    /// is preserved rather than normalised away.
    private func applyDueDate(_ date: Date?, hasTime: Bool, to reminder: EKReminder) {
        guard let date else {
            reminder.dueDateComponents = nil
            return
        }
        let units: Set<Calendar.Component> = hasTime
            ? [.year, .month, .day, .hour, .minute, .second, .timeZone]
            : [.year, .month, .day]
        reminder.dueDateComponents = calendar.dateComponents(units, from: date)
    }

    private func existingDueDate(_ reminder: EKReminder) -> Date? {
        reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
    }

    private func map(_ reminder: EKReminder) -> Reminder? {
        Self.map(reminder, calendar: calendar)
    }

    private nonisolated static func map(_ reminder: EKReminder, calendar: Calendar) -> Reminder? {
        guard let list = reminder.calendar else { return nil }
        let components = reminder.dueDateComponents
        return Reminder(
            id: ReminderIdentifier(reminder.calendarItemIdentifier),
            title: reminder.title ?? "",
            dueDate: components.flatMap { calendar.date(from: $0) },
            hasTimeComponent: components?.hour != nil,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            listID: CalendarIdentifier(list.calendarIdentifier),
            listTitle: list.title,
            notes: reminder.notes?.isEmpty == false ? reminder.notes : nil,
            alerts: EventKitMapping.alerts(reminder.alarms)
        )
    }

    private func verifyExists(_ identifier: String, context: String) throws -> Reminder {
        guard !identifier.isEmpty else {
            throw ReminderServiceError.verificationFailed("\(context) has no identifier")
        }
        guard let saved = store.calendarItem(withIdentifier: identifier) as? EKReminder,
              let mapped = map(saved)
        else {
            throw ReminderServiceError.verificationFailed("I couldn't read back \(context)")
        }
        return mapped
    }

    /// Undated reminders sort last; otherwise earliest due first.
    private static func dueDateOrder(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case (nil, nil): lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        case (nil, _): false
        case (_, nil): true
        case (let left?, let right?): left < right
        }
    }
}
