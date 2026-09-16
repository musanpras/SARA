import Foundation

/// Executes validated reminder operations. Mirrors `CalendarTool`.
public struct ReminderTool: Sendable {
    private let service: any ReminderService
    private let history: ActionHistory
    private let dateProvider: DateProvider
    private let phrasing: DatePhrasing

    public init(service: any ReminderService, history: ActionHistory, dateProvider: DateProvider) {
        self.service = service
        self.history = history
        self.dateProvider = dateProvider
        self.phrasing = DatePhrasing(calendar: dateProvider.calendar)
    }

    public func execute(_ operation: ExecutableOperation) async throws -> ActionResult {
        switch operation {
        case .createReminder(let draft):
            return try await create(draft)
        case .searchReminders(let query):
            return try await search(query)
        case .updateReminder(let target, let changes):
            return try await update(target: target, changes: changes)
        case .deleteReminder(let target):
            return try await delete(target: target)
        default:
            throw ActionFailure(message: "That isn't a reminder operation.")
        }
    }

    private func create(_ draft: ReminderDraft) async throws -> ActionResult {
        do {
            let reminder = try await service.create(draft)
            await history.record(
                HistoryEntry(
                    timestamp: dateProvider.now,
                    summary: "creating the reminder \(phrasing.describe(reminder, relativeTo: dateProvider.now))",
                    reversal: .deleteCreatedReminder(reminder.id)
                )
            )
            return .createdReminder(reminder)
        } catch let error as ReminderServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    private func search(_ query: ReminderSearchQuery) async throws -> ActionResult {
        do {
            var reminders = try await service.reminders(
                dueIn: query.interval,
                listIDs: query.listIDs,
                filter: query.completion
            )
            if let fragment = query.titleContains, !fragment.isEmpty {
                reminders = reminders.filter { $0.title.localizedCaseInsensitiveContains(fragment) }
            }
            return .foundReminders(reminders)
        } catch let error as ReminderServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    private func update(target: Reminder, changes: ReminderChanges) async throws -> ActionResult {
        do {
            let after = try await service.update(id: target.id, changes: changes)
            await history.record(
                HistoryEntry(
                    timestamp: dateProvider.now,
                    summary: "changing the reminder \(phrasing.describe(target, relativeTo: dateProvider.now))",
                    reversal: .restoreReminder(id: after.id, changes: Self.inverse(of: changes, restoring: target))
                )
            )
            return .updatedReminder(before: target, after: after)
        } catch let error as ReminderServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    private func delete(target: Reminder) async throws -> ActionResult {
        do {
            try await service.delete(id: target.id)
            return .deletedReminder(target)
        } catch let error as ReminderServiceError {
            throw ActionFailure(message: error.userMessage)
        }
    }

    static func inverse(
        of changes: ReminderChanges,
        restoring previous: Reminder
    ) -> ReminderChanges {
        ReminderChanges(
            title: changes.title == nil ? nil : previous.title,
            dueDate: (changes.dueDate == nil && !changes.clearDueDate) ? nil : previous.dueDate,
            hasTimeComponent: (changes.hasTimeComponent == nil && !changes.clearDueDate)
                ? nil
                : previous.hasTimeComponent,
            // Restoring a cleared due date means putting the old one back, which
            // is only possible when there was one.
            clearDueDate: changes.dueDate != nil && previous.dueDate == nil,
            isCompleted: changes.isCompleted == nil ? nil : previous.isCompleted,
            listID: changes.listID == nil ? nil : previous.listID,
            notes: changes.notes == nil ? nil : (previous.notes ?? ""),
            alerts: changes.alerts == nil ? nil : previous.alerts
        )
    }
}
