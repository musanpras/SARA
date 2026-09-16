import Foundation

public enum MemoryStoreError: Error, Sendable {
    case unavailable(String)
    case underlying(String)

    public var userMessage: String {
        switch self {
        case .unavailable, .underlying:
            "I couldn't reach my own notes just now."
        }
    }
}

/// SARA's local-first memory.
///
/// Four distinct things, deliberately kept apart: settings the user chose,
/// what SARA did (so it can be undone), what was said (so a conversation can
/// resume), and what is worth recalling later. EventKit records are never
/// duplicated into any of them.
///
/// Every method is failable because storage can genuinely fail, and a memory
/// failure must never be mistaken for "the user has no preferences".
public protocol MemoryStore: Sendable {
    // MARK: Preferences

    /// `nil` when the user has never changed anything.
    func loadPreferences() async throws -> SARAPreferences?
    func savePreferences(_ preferences: SARAPreferences) async throws

    // MARK: Action history

    func appendHistory(_ entry: HistoryEntry) async throws
    /// Newest last, matching the order `ActionHistory` works in.
    func loadHistory(limit: Int) async throws -> [HistoryEntry]
    func removeHistory(id: UUID) async throws
    func clearHistory() async throws

    // MARK: Session

    func appendTurn(_ message: ConversationMessage) async throws
    /// Newest last.
    func loadTurns(limit: Int) async throws -> [ConversationMessage]
    func clearTurns() async throws

    // MARK: Memories

    /// Adds a memory, or reinforces the existing one with the same subject and
    /// kind rather than accumulating near-duplicates.
    func remember(_ memory: MemoryRecord) async throws
    /// Ranked recall. Implementations mark what they return as used, which is
    /// what makes recency and use counts mean anything.
    func recall(_ query: MemoryQuery) async throws -> [ScoredMemory]
    func forget(id: UUID) async throws
    func clearMemories() async throws
}

public extension MemoryStore {
    /// Loads stored preferences, falling back to the defaults.
    ///
    /// A storage failure is reported rather than silently returning defaults,
    /// because quietly discarding a user's settings looks identical to
    /// ignoring them.
    func preferencesOrDefault() async throws -> SARAPreferences {
        try await loadPreferences() ?? .default
    }
}

/// Subjects SARA writes memories under.
///
/// Centralised so a writer and a reader cannot drift apart over a string.
public enum MemorySubject {
    /// Which calendar the user picked when several matched by name.
    public static func calendarChoice(forName name: String) -> String {
        "calendar-choice:\(name.lowercased())"
    }

    /// Which reminders list the user picked when several matched by name.
    public static func listChoice(forName name: String) -> String {
        "list-choice:\(name.lowercased())"
    }
}
