import Foundation

/// How a completed action can be taken back.
///
/// Only operations with a clean inverse appear here. Re-creating a deleted
/// record is deliberately absent: EventKit would mint a new identifier and drop
/// series membership, so SARA says it cannot undo a deletion rather than
/// producing a lookalike.
public enum Reversal: Hashable, Sendable, Codable {
    case deleteCreatedEvent(EventIdentifier)
    case deleteCreatedReminder(ReminderIdentifier)
    case restoreEvent(id: EventIdentifier, changes: CalendarEventChanges)
    case restoreReminder(id: ReminderIdentifier, changes: ReminderChanges)
}

/// One recorded, reversible action.
public struct HistoryEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let timestamp: Date
    /// What SARA will say it undid, e.g. "creating Gym tomorrow at 4 PM".
    public let summary: String
    public let reversal: Reversal

    public init(id: UUID = UUID(), timestamp: Date, summary: String, reversal: Reversal) {
        self.id = id
        self.timestamp = timestamp
        self.summary = summary
        self.reversal = reversal
    }
}

/// Recent reversible actions, newest last.
///
/// An actor because execution and the UI both touch it. Bounded, because undo
/// is a short-term affordance, not an audit log.
///
/// When a `MemoryStore` is supplied, entries are written through to it so
/// "undo that" still works after the app is relaunched.
public actor ActionHistory {
    private var entries: [HistoryEntry] = []
    private let capacity: Int
    private let store: (any MemoryStore)?

    /// The last storage failure, if any.
    ///
    /// Persistence problems are recorded rather than thrown: the calendar write
    /// they follow has already succeeded, and failing it afterwards would be a
    /// lie. Undo still works for the current session; it just will not survive
    /// a relaunch, and the UI can say so.
    public private(set) var persistenceFailure: MemoryStoreError?

    public init(capacity: Int = 50, store: (any MemoryStore)? = nil) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.store = store
    }

    /// Loads previously stored entries. Call once at start-up.
    public func restore() async {
        guard let store else { return }
        do {
            entries = try await store.loadHistory(limit: capacity)
            persistenceFailure = nil
        } catch let error as MemoryStoreError {
            persistenceFailure = error
        } catch {
            persistenceFailure = .underlying(error.localizedDescription)
        }
    }

    public func record(_ entry: HistoryEntry) async {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        await persist { try await $0.appendHistory(entry) }
    }

    public var canUndo: Bool { !entries.isEmpty }

    public var mostRecent: HistoryEntry? { entries.last }

    public var all: [HistoryEntry] { entries }

    /// Removes and returns the newest entry, so an undo cannot run twice.
    public func popMostRecent() async -> HistoryEntry? {
        guard let entry = entries.popLast() else { return nil }
        await persist { try await $0.removeHistory(id: entry.id) }
        return entry
    }

    public func removeAll() async {
        entries.removeAll()
        await persist { try await $0.clearHistory() }
    }

    private func persist(_ work: (any MemoryStore) async throws -> Void) async {
        guard let store else { return }
        do {
            try await work(store)
            persistenceFailure = nil
        } catch let error as MemoryStoreError {
            persistenceFailure = error
        } catch {
            persistenceFailure = .underlying(error.localizedDescription)
        }
    }
}
