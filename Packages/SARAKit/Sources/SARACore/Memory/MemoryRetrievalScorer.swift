import Foundation

/// Where a future semantic index plugs in.
///
/// MVP retrieval is structured plus lexical. When an embedding model is
/// available it supplies this score, and the weights below make room for it
/// without any other change.
public protocol SemanticSimilarityProviding: Sendable {
    /// Similarity in 0...1 between a query and a stored memory.
    func similarity(of query: String, to content: String) async -> Double
}

/// Ranks memories by combining structured agreement, lexical relevance,
/// recency and use.
///
/// Deliberately a pure function of its inputs: the same query against the same
/// memories always produces the same order, which is what makes retrieval
/// testable rather than merely plausible.
public struct MemoryRetrievalScorer: Sendable {
    public struct Weights: Hashable, Sendable {
        public var structured: Double
        public var relevance: Double
        public var recency: Double
        public var usage: Double
        /// Added to the total for a memory the user pinned.
        public var pinnedBonus: Double
        /// Time for the recency score to halve.
        public var recencyHalfLife: TimeInterval

        public init(
            structured: Double = 0.45,
            relevance: Double = 0.30,
            recency: Double = 0.15,
            usage: Double = 0.10,
            pinnedBonus: Double = 0.25,
            recencyHalfLife: TimeInterval = 14 * 86_400
        ) {
            self.structured = structured
            self.relevance = relevance
            self.recency = recency
            self.usage = usage
            self.pinnedBonus = pinnedBonus
            self.recencyHalfLife = recencyHalfLife
        }

        public static let `default` = Weights()
    }

    private let weights: Weights

    public init(weights: Weights = .default) {
        self.weights = weights
    }

    /// Scores and orders `memories`, dropping anything with no signal at all.
    ///
    /// A memory that matches nothing about the query is omitted rather than
    /// ranked last, so an unrelated query recalls nothing instead of recalling
    /// the newest thing in the store.
    public func rank(_ memories: [MemoryRecord], for query: MemoryQuery) -> [ScoredMemory] {
        let queryTerms = Set(query.text.map(MemoryRecord.terms(in:)) ?? [])

        let scored = memories.compactMap { memory -> ScoredMemory? in
            if !query.kinds.isEmpty && !query.kinds.contains(memory.kind) { return nil }

            // A subject lookup is exact by definition: anything else is a
            // different memory that happens to be in the store, and returning
            // it would let a caller act on the wrong one.
            if let subject = query.subject,
               memory.subject.localizedCaseInsensitiveCompare(subject) != .orderedSame {
                return nil
            }

            let structured = structuredScore(memory, query: query, queryTerms: queryTerms)
            let relevance = relevanceScore(memory, queryTerms: queryTerms)
            let recency = recencyScore(memory, now: query.now)
            let usage = usageScore(memory)

            // With no query text, recall is "the most useful memories of this
            // kind", so recency and use alone are enough to qualify.
            let hasSignal = queryTerms.isEmpty || structured > 0 || relevance > 0
            guard hasSignal else { return nil }

            var total = structured * weights.structured
                + relevance * weights.relevance
                + recency * weights.recency
                + usage * weights.usage
            if memory.pinned { total += weights.pinnedBonus }

            return ScoredMemory(
                memory: memory,
                structuredScore: structured,
                relevanceScore: relevance,
                recencyScore: recency,
                usageScore: usage,
                total: total
            )
        }

        return scored
            .sorted { lhs, rhs in
                // Ties break on recency, then on identifier, so the order is
                // stable across runs rather than dependent on dictionary order.
                if lhs.total != rhs.total { return lhs.total > rhs.total }
                if lhs.memory.lastAccessedAt != rhs.memory.lastAccessedAt {
                    return lhs.memory.lastAccessedAt > rhs.memory.lastAccessedAt
                }
                return lhs.memory.id.uuidString < rhs.memory.id.uuidString
            }
            .prefix(max(0, query.limit))
            .map { $0 }
    }

    // MARK: - Components

    /// An exact subject match is the strongest signal there is; otherwise this
    /// measures how much of the query the memory's keywords account for.
    private func structuredScore(
        _ memory: MemoryRecord,
        query: MemoryQuery,
        queryTerms: Set<String>
    ) -> Double {
        if let subject = query.subject {
            return memory.subject.localizedCaseInsensitiveCompare(subject) == .orderedSame ? 1 : 0
        }
        guard !queryTerms.isEmpty else { return 0 }
        let keywords = Set(memory.keywords)
        let overlap = keywords.intersection(queryTerms).count
        return Double(overlap) / Double(queryTerms.count)
    }

    /// Jaccard overlap between the query's terms and the memory's own text.
    private func relevanceScore(_ memory: MemoryRecord, queryTerms: Set<String>) -> Double {
        guard !queryTerms.isEmpty else { return 0 }
        let memoryTerms = Set(MemoryRecord.terms(in: "\(memory.subject) \(memory.content)"))
        guard !memoryTerms.isEmpty else { return 0 }

        let union = memoryTerms.union(queryTerms).count
        guard union > 0 else { return 0 }
        return Double(memoryTerms.intersection(queryTerms).count) / Double(union)
    }

    /// Exponential decay, so a memory used today outranks one used last month
    /// without a stale memory ever dropping to exactly zero.
    private func recencyScore(_ memory: MemoryRecord, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(memory.lastAccessedAt))
        return pow(0.5, age / weights.recencyHalfLife)
    }

    /// Logarithmic, so repeated use counts without one habit drowning out
    /// everything else.
    private func usageScore(_ memory: MemoryRecord) -> Double {
        guard memory.useCount > 0 else { return 0 }
        return min(1, log(Double(memory.useCount) + 1) / log(11))
    }
}
