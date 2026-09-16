import Foundation

/// Dispatches a validated operation to the tool that owns it.
///
/// Adding a future tool (Notes, Messages) means adding a case here and a new
/// `ExecutableOperation`; nothing upstream changes.
public struct ToolRouter: Sendable {
    private let calendarTool: CalendarTool
    private let reminderTool: ReminderTool
    private let calendarService: any CalendarService
    private let reminderService: any ReminderService
    private let history: ActionHistory

    public init(
        calendarService: any CalendarService,
        reminderService: any ReminderService,
        history: ActionHistory,
        dateProvider: DateProvider
    ) {
        self.calendarService = calendarService
        self.reminderService = reminderService
        self.history = history
        self.calendarTool = CalendarTool(
            service: calendarService,
            history: history,
            dateProvider: dateProvider
        )
        self.reminderTool = ReminderTool(
            service: reminderService,
            history: history,
            dateProvider: dateProvider
        )
    }

    public func execute(_ operation: ExecutableOperation) async throws -> ActionResult {
        switch operation {
        case .createEvent, .searchEvents, .updateEvent, .deleteEvent:
            return try await calendarTool.execute(operation)
        case .createReminder, .searchReminders, .updateReminder, .deleteReminder:
            return try await reminderTool.execute(operation)
        case .undoLastAction:
            return try await undo()
        }
    }

    /// Reverses the most recent recorded action.
    ///
    /// The entry is consumed whether or not the reversal succeeds, so a failing
    /// undo cannot be retried into an inconsistent state by repeating the
    /// command.
    private func undo() async throws -> ActionResult {
        guard let entry = await history.popMostRecent() else {
            throw ActionFailure(message: "There's nothing for me to undo.")
        }

        do {
            switch entry.reversal {
            case .deleteCreatedEvent(let id):
                try await calendarService.delete(id: id, span: .thisEvent)
            case .deleteCreatedReminder(let id):
                try await reminderService.delete(id: id)
            case .restoreEvent(let id, let changes):
                _ = try await calendarService.update(id: id, changes: changes, span: .thisEvent)
            case .restoreReminder(let id, let changes):
                _ = try await reminderService.update(id: id, changes: changes)
            }
        } catch let error as CalendarServiceError {
            throw ActionFailure(message: "I couldn't undo \(entry.summary): \(error.userMessage)")
        } catch let error as ReminderServiceError {
            throw ActionFailure(message: "I couldn't undo \(entry.summary): \(error.userMessage)")
        }

        return .undone(summary: entry.summary)
    }
}
