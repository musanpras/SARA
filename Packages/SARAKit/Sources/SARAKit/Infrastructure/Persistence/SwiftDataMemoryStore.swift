import Foundation
import SARACore
import SwiftData

/// SwiftData-backed local storage for preferences, history, session turns and
/// memories.
///
/// A `@ModelActor`, because `ModelContext` is not thread-safe and every read
/// and write has to happen on the actor that owns it. Nothing here is synced
/// anywhere: SARA is local-first, and CloudKit is a later decision this schema
/// deliberately stays compatible with.
@ModelActor
public actor SwiftDataMemoryStore: MemoryStore {
    private var scorer: MemoryRetrievalScorer { MemoryRetrievalScorer() }
    /// Bounds on what is kept. Memory is a working aid, not an archive.
    private var historyCapacity: Int { 100 }
    private var turnCapacity: Int { 200 }
    private var memoryCapacity: Int { 500 }

    private var encoder: JSONEncoder { JSONEncoder() }
    private var decoder: JSONDecoder { JSONDecoder() }

    /// The schema SARA stores. Exposed so the app and tests build the same one.
    public static var schema: Schema {
        Schema([
            PersistedPreferences.self,
            PersistedHistoryEntry.self,
            PersistedTurn.self,
            PersistedMemory.self,
        ])
    }

    /// Opens the on-disk store.
    ///
    /// Throws rather than falling back silently: the caller decides whether to
    /// degrade to in-memory storage, and the user deserves to be told that
    /// SARA will forget things.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        )
    }

    // MARK: - Preferences

    public func loadPreferences() async throws -> SARAPreferences? {
        let key = PersistedPreferences.singletonKey
        var descriptor = FetchDescriptor<PersistedPreferences>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        guard let row = try fetch(descriptor).first else { return nil }
        do {
            return try decoder.decode(SARAPreferences.self, from: row.payload)
        } catch {
            // Preferences written by an incompatible build are discarded rather
            // than blocking start-up; the user re-states them, and the defaults
            // are safe in the meantime.
            modelContext.delete(row)
            try save()
            return nil
        }
    }

    public func savePreferences(_ preferences: SARAPreferences) async throws {
        let payload = try encoder.encode(preferences)
        let key = PersistedPreferences.singletonKey
        var descriptor = FetchDescriptor<PersistedPreferences>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try fetch(descriptor).first {
            existing.payload = payload
            existing.updatedAt = Date()
        } else {
            modelContext.insert(PersistedPreferences(payload: payload, updatedAt: Date()))
        }
        try save()
    }

    // MARK: - Action history

    public func appendHistory(_ entry: HistoryEntry) async throws {
        modelContext.insert(try PersistedHistoryEntry(entry, encoder: encoder))
        try save()
        try prune(
            FetchDescriptor<PersistedHistoryEntry>(
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            ),
            capacity: historyCapacity
        )
    }

    public func loadHistory(limit: Int) async throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<PersistedHistoryEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        // Fetched newest first for the limit, then reversed: callers work with
        // history oldest first, newest last.
        return try fetch(descriptor)
            .compactMap { try? $0.toDomain(decoder: decoder) }
            .reversed()
    }

    public func removeHistory(id: UUID) async throws {
        let descriptor = FetchDescriptor<PersistedHistoryEntry>(
            predicate: #Predicate { $0.identifier == id }
        )
        for row in try fetch(descriptor) {
            modelContext.delete(row)
        }
        try save()
    }

    public func clearHistory() async throws {
        try modelContext.delete(model: PersistedHistoryEntry.self)
        try save()
    }

    // MARK: - Session

    public func appendTurn(_ message: ConversationMessage) async throws {
        modelContext.insert(PersistedTurn(message))
        try save()
        try prune(
            FetchDescriptor<PersistedTurn>(sortBy: [SortDescriptor(\.timestamp, order: .forward)]),
            capacity: turnCapacity
        )
    }

    public func loadTurns(limit: Int) async throws -> [ConversationMessage] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<PersistedTurn>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        return try fetch(descriptor)
            .compactMap { $0.toDomain() }
            .reversed()
    }

    public func clearTurns() async throws {
        try modelContext.delete(model: PersistedTurn.self)
        try save()
    }

    // MARK: - Memories

    public func remember(_ memory: MemoryRecord) async throws {
        let kind = memory.kind.rawValue
        let subject = memory.subject
        let descriptor = FetchDescriptor<PersistedMemory>(
            predicate: #Predicate { $0.kind == kind && $0.subject == subject }
        )

        if let existing = try fetch(descriptor).first, let current = existing.toDomain() {
            existing.apply(MemoryReinforcement.merge(memory, into: current))
        } else {
            modelContext.insert(PersistedMemory(memory))
        }
        try save()
        try pruneMemories()
    }

    public func recall(_ query: MemoryQuery) async throws -> [ScoredMemory] {
        let rows = try fetch(FetchDescriptor<PersistedMemory>())
        let records = rows.compactMap { $0.toDomain() }
        let ranked = scorer.rank(records, for: query)

        // Recall is a use: it is what keeps recency and use counts meaningful.
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0) })
        for scored in ranked {
            guard let row = byID[scored.id], let current = row.toDomain() else { continue }
            row.apply(MemoryReinforcement.markUsed(current, at: query.now))
        }
        try save()

        return ranked
    }

    public func forget(id: UUID) async throws {
        let descriptor = FetchDescriptor<PersistedMemory>(
            predicate: #Predicate { $0.identifier == id }
        )
        for row in try fetch(descriptor) {
            modelContext.delete(row)
        }
        try save()
    }

    public func clearMemories() async throws {
        try modelContext.delete(model: PersistedMemory.self)
        try save()
    }

    // MARK: - Plumbing

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw MemoryStoreError.underlying(error.localizedDescription)
        }
    }

    private func save() throws {
        do {
            try modelContext.save()
        } catch {
            throw MemoryStoreError.underlying(error.localizedDescription)
        }
    }

    /// Drops the oldest rows once a table is over its cap.
    private func prune<T: PersistentModel>(_ oldestFirst: FetchDescriptor<T>, capacity: Int) throws {
        let rows = try fetch(oldestFirst)
        guard rows.count > capacity else { return }
        for row in rows.prefix(rows.count - capacity) {
            modelContext.delete(row)
        }
        try save()
    }

    /// Memories are evicted by least-recent use rather than age, and pinned
    /// ones are kept regardless.
    private func pruneMemories() throws {
        let rows = try fetch(FetchDescriptor<PersistedMemory>())
        guard rows.count > memoryCapacity else { return }

        let records = rows.compactMap { $0.toDomain() }
        let doomed = Set(
            MemoryReinforcement
                .evictionCandidates(from: records, capacity: memoryCapacity)
                .map(\.id)
        )
        for row in rows where doomed.contains(row.identifier) {
            modelContext.delete(row)
        }
        try save()
    }
}
