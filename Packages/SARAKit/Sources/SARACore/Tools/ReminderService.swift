import Foundation

public enum ReminderServiceError: Error, Hashable, Sendable {
    case permission(PermissionError)
    case reminderNotFound(ReminderIdentifier)
    case listNotFound(CalendarIdentifier)
    case listIsReadOnly(CalendarIdentifier)
    case noWritableList
    case verificationFailed(String)
    case underlying(String)

    public var userMessage: String {
        switch self {
        case .permission(let error): error.userMessage
        case .reminderNotFound: "I couldn't find that reminder any more — it may have been removed."
        case .listNotFound: "I couldn't find that reminders list."
        case .listIsReadOnly: "That reminders list is read-only, so I can't change it."
        case .noWritableList: "There's no reminders list I'm allowed to write to."
        case .verificationFailed(let detail): "I couldn't confirm the change went through: \(detail)"
        case .underlying(let detail): "The reminders operation failed: \(detail)"
        }
    }
}

/// The only way SARA touches reminder data. Mirrors `CalendarService`,
/// including its verify-after-write contract.
public protocol ReminderService: Sendable {
    func authorizationStatus() async -> PermissionStatus
    @discardableResult
    func requestAccess() async -> PermissionStatus

    func lists() async throws -> [ReminderListDescriptor]
    func defaultList() async throws -> ReminderListDescriptor?

    /// Reminders due inside `interval`, or all undated ones when `interval` is nil.
    func reminders(
        dueIn interval: DateInterval?,
        listIDs: [CalendarIdentifier]?,
        filter: ReminderCompletionFilter
    ) async throws -> [Reminder]

    func reminder(id: ReminderIdentifier) async throws -> Reminder?

    func create(_ draft: ReminderDraft) async throws -> Reminder
    func update(id: ReminderIdentifier, changes: ReminderChanges) async throws -> Reminder
    func delete(id: ReminderIdentifier) async throws
}

public extension ReminderService {
    func reminders(dueIn interval: DateInterval?) async throws -> [Reminder] {
        try await reminders(dueIn: interval, listIDs: nil, filter: .incompleteOnly)
    }
}
