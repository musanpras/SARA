import Foundation

/// The parts of `remember` and `recall` that must behave identically in every
/// store, kept in one place so the SwiftData and in-memory implementations
/// cannot quietly disagree.
public enum MemoryReinforcement {
    /// Merges a new memory into an existing one with the same subject and kind.
    ///
    /// Repeating a choice should strengthen it rather than create a second,
    /// competing memory — otherwise the store fills with near-duplicates that
    /// split the score between them.
    public static func merge(_ incoming: MemoryRecord, into existing: MemoryRecord) -> MemoryRecord {
        MemoryRecord(
            id: existing.id,
            kind: existing.kind,
            subject: existing.subject,
            content: incoming.content,
            keywords: incoming.keywords,
            createdAt: existing.createdAt,
            lastAccessedAt: max(existing.lastAccessedAt, incoming.createdAt),
            useCount: existing.useCount + 1,
            // Pinning is sticky: the user asked for it once.
            pinned: existing.pinned || incoming.pinned
        )
    }

    /// Records that a memory was recalled, which feeds recency and use.
    public static func markUsed(_ memory: MemoryRecord, at date: Date) -> MemoryRecord {
        MemoryRecord(
            id: memory.id,
            kind: memory.kind,
            subject: memory.subject,
            content: memory.content,
            keywords: memory.keywords,
            createdAt: memory.createdAt,
            lastAccessedAt: date,
            useCount: memory.useCount + 1,
            pinned: memory.pinned
        )
    }

    /// Memories to evict once the store is over capacity.
    ///
    /// Pinned memories are never evicted; otherwise the least recently used go
    /// first, which is the behaviour a user would predict.
    public static func evictionCandidates(
        from memories: [MemoryRecord],
        capacity: Int
    ) -> [MemoryRecord] {
        let unpinned = memories.filter { !$0.pinned }
        let overflow = memories.count - capacity
        guard overflow > 0, !unpinned.isEmpty else { return [] }

        return unpinned
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            .prefix(min(overflow, unpinned.count))
            .map { $0 }
    }
}
