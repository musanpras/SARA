import Foundation
import SARACore

/// A `MemoryStore` held entirely in memory.
///
/// Used by tests, and as the fallback when SwiftData cannot open its database —
/// SARA degrades to forgetting between launches rather than refusing to run.
public actor InMemoryMemoryStore: MemoryStore {
    private var preferences: SARAPreferences?
    private var history: [HistoryEntry] = []
    private var turns: [ConversationMessage] = []
    private var memories: [MemoryRecord] = []

    private let scorer: MemoryRetrievalScorer
    private let memoryCapacity: Int

    /// When set, the next call throws it. Lets tests prove that a memory
    /// failure is surfaced rather than mistaken for "nothing stored".
    public var failureToInject: MemoryStoreError?

    public init(
        preferences: SARAPreferences? = nil,
        memories: [MemoryRecord] = [],
        scorer: MemoryRetrievalScorer = MemoryRetrievalScorer(),
        memoryCapacity: Int = 200
    ) {
        self.preferences = preferences
        self.memories = memories
        self.scorer = scorer
        self.memoryCapacity = memoryCapacity
    }

    public func setFailure(_ failure: MemoryStoreError?) { failureToInject = failure }

    private func takeInjectedFailure() throws {
        if let failure = failureToInject {
            failureToInject = nil
            throw failure
        }
    }

    // MARK: Preferences

    public func loadPreferences() async throws -> SARAPreferences? {
        try takeInjectedFailure()
        return preferences
    }

    public func savePreferences(_ preferences: SARAPreferences) async throws {
        try takeInjectedFailure()
        self.preferences = preferences
    }

    // MARK: History

    public func appendHistory(_ entry: HistoryEntry) async throws {
        try takeInjectedFailure()
        history.append(entry)
    }

    public func loadHistory(limit: Int) async throws -> [HistoryEntry] {
        try takeInjectedFailure()
        return Array(history.suffix(max(0, limit)))
    }

    public func removeHistory(id: UUID) async throws {
        try takeInjectedFailure()
        history.removeAll { $0.id == id }
    }

    public func clearHistory() async throws {
        try takeInjectedFailure()
        history.removeAll()
    }

    // MARK: Session

    public func appendTurn(_ message: ConversationMessage) async throws {
        try takeInjectedFailure()
        turns.append(message)
    }

    public func loadTurns(limit: Int) async throws -> [ConversationMessage] {
        try takeInjectedFailure()
        return Array(turns.suffix(max(0, limit)))
    }

    public func clearTurns() async throws {
        try takeInjectedFailure()
        turns.removeAll()
    }

    // MARK: Memories

    public func remember(_ memory: MemoryRecord) async throws {
        try takeInjectedFailure()

        if let index = memories.firstIndex(where: {
            $0.kind == memory.kind
                && $0.subject.localizedCaseInsensitiveCompare(memory.subject) == .orderedSame
        }) {
            memories[index] = MemoryReinforcement.merge(memory, into: memories[index])
        } else {
            memories.append(memory)
        }

        let evicted = MemoryReinforcement.evictionCandidates(from: memories, capacity: memoryCapacity)
        let ids = Set(evicted.map(\.id))
        memories.removeAll { ids.contains($0.id) }
    }

    public func recall(_ query: MemoryQuery) async throws -> [ScoredMemory] {
        try takeInjectedFailure()

        let ranked = scorer.rank(memories, for: query)
        for scored in ranked {
            guard let index = memories.firstIndex(where: { $0.id == scored.id }) else { continue }
            memories[index] = MemoryReinforcement.markUsed(memories[index], at: query.now)
        }
        return ranked
    }

    public func forget(id: UUID) async throws {
        try takeInjectedFailure()
        memories.removeAll { $0.id == id }
    }

    public func clearMemories() async throws {
        try takeInjectedFailure()
        memories.removeAll()
    }

    // MARK: Test introspection

    public var storedMemories: [MemoryRecord] { memories }
    public var storedHistoryCount: Int { history.count }
    public var storedTurnCount: Int { turns.count }
}
