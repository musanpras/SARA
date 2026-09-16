import Foundation
import SARACore

/// In-memory `ReminderService`, matching `InMemoryCalendarService` in intent.
public actor InMemoryReminderService: ReminderService {
    private var storedReminders: [ReminderIdentifier: Reminder] = [:]
    private var storedLists: [ReminderListDescriptor]
    private var status: PermissionStatus
    private var nextID = 1

    public var failureToInject: ReminderServiceError?
    public private(set) var createCount = 0
    public private(set) var updateCount = 0
    public private(set) var deleteCount = 0

    public init(
        lists: [ReminderListDescriptor] = [.defaultList],
        reminders: [Reminder] = [],
        status: PermissionStatus = .authorized
    ) {
        self.storedLists = lists
        self.status = status
        for reminder in reminders { storedReminders[reminder.id] = reminder }
    }

    // MARK: - Test control

    public func setStatus(_ status: PermissionStatus) { self.status = status }
    public func setFailure(_ failure: ReminderServiceError?) { failureToInject = failure }
    public func seed(_ reminders: [Reminder]) {
        for reminder in reminders { storedReminders[reminder.id] = reminder }
    }
    public var allReminders: [Reminder] {
        storedReminders.values.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    // MARK: - ReminderService

    public func authorizationStatus() async -> PermissionStatus { status }

    @discardableResult
    public func requestAccess() async -> PermissionStatus {
        if status == .notDetermined { status = .authorized }
        return status
    }

    private func requireAccess(write: Bool) throws {
        let ok = write ? status.canWrite : status.canRead
        guard ok else {
            throw ReminderServiceError.permission(PermissionError(capability: .reminders, status: status))
        }
    }

    private func takeInjectedFailure() throws {
        if let failure = failureToInject {
            failureToInject = nil
            throw failure
        }
    }

    public func lists() async throws -> [ReminderListDescriptor] {
        try requireAccess(write: false)
        return storedLists
    }

    public func defaultList() async throws -> ReminderListDescriptor? {
        try requireAccess(write: false)
        return storedLists.first(where: \.isDefaultForNewReminders) ?? storedLists.first
    }

    public func reminders(
        dueIn interval: DateInterval?,
        listIDs: [CalendarIdentifier]?,
        filter: ReminderCompletionFilter
    ) async throws -> [Reminder] {
        try requireAccess(write: false)
        let wanted = listIDs.map(Set.init)

        return storedReminders.values
            .filter { reminder in
                switch filter {
                case .incompleteOnly: !reminder.isCompleted
                case .completedOnly: reminder.isCompleted
                case .all: true
                }
            }
            .filter { wanted == nil || wanted!.contains($0.listID) }
            .filter { reminder in
                guard let interval else { return true }
                guard let due = reminder.dueDate else { return false }
                return interval.contains(due)
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    public func reminder(id: ReminderIdentifier) async throws -> Reminder? {
        try requireAccess(write: false)
        return storedReminders[id]
    }

    public func create(_ draft: ReminderDraft) async throws -> Reminder {
        try requireAccess(write: true)
        try takeInjectedFailure()

        let list = try resolveList(draft.listID)
        let id = ReminderIdentifier("reminder-\(nextID)")
        nextID += 1

        let reminder = Reminder(
            id: id,
            title: draft.title,
            dueDate: draft.dueDate,
            hasTimeComponent: draft.dueDate == nil ? false : draft.hasTimeComponent,
            isCompleted: false,
            listID: list.id,
            listTitle: list.title,
            notes: draft.notes,
            alerts: draft.alerts
        )
        storedReminders[id] = reminder
        createCount += 1
        return reminder
    }

    public func update(id: ReminderIdentifier, changes: ReminderChanges) async throws -> Reminder {
        try requireAccess(write: true)
        try takeInjectedFailure()

        guard let existing = storedReminders[id] else {
            throw ReminderServiceError.reminderNotFound(id)
        }
        let list = try changes.listID.map { try resolveList($0) }

        let dueDate: Date? = changes.clearDueDate ? nil : (changes.dueDate ?? existing.dueDate)
        let isCompleted = changes.isCompleted ?? existing.isCompleted

        let updated = Reminder(
            id: id,
            title: changes.title ?? existing.title,
            dueDate: dueDate,
            hasTimeComponent: dueDate == nil
                ? false
                : (changes.hasTimeComponent ?? existing.hasTimeComponent),
            isCompleted: isCompleted,
            completionDate: isCompleted ? (existing.completionDate ?? dueDate) : nil,
            listID: list?.id ?? existing.listID,
            listTitle: list?.title ?? existing.listTitle,
            notes: changes.notes ?? existing.notes,
            alerts: changes.alerts ?? existing.alerts
        )
        storedReminders[id] = updated
        updateCount += 1
        return updated
    }

    public func delete(id: ReminderIdentifier) async throws {
        try requireAccess(write: true)
        try takeInjectedFailure()

        guard storedReminders[id] != nil else {
            throw ReminderServiceError.reminderNotFound(id)
        }
        storedReminders[id] = nil
        deleteCount += 1
    }

    private func resolveList(_ id: CalendarIdentifier?) throws -> ReminderListDescriptor {
        if let id {
            guard let match = storedLists.first(where: { $0.id == id }) else {
                throw ReminderServiceError.listNotFound(id)
            }
            guard match.allowsModification else {
                throw ReminderServiceError.listIsReadOnly(id)
            }
            return match
        }
        guard let fallback = storedLists.first(where: { $0.isDefaultForNewReminders && $0.allowsModification })
            ?? storedLists.first(where: \.allowsModification)
        else {
            throw ReminderServiceError.noWritableList
        }
        return fallback
    }
}

public extension ReminderListDescriptor {
    static let defaultList = ReminderListDescriptor(
        id: CalendarIdentifier("list-reminders"),
        title: "Reminders",
        sourceTitle: "iCloud",
        allowsModification: true,
        isDefaultForNewReminders: true
    )

    static let groceries = ReminderListDescriptor(
        id: CalendarIdentifier("list-groceries"),
        title: "Groceries",
        sourceTitle: "iCloud",
        allowsModification: true,
        isDefaultForNewReminders: false
    )
}
