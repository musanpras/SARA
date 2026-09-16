import Foundation
import Testing
@testable import SARACore

@Suite("Memory retrieval")
struct MemoryRetrievalTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800)
    private let scorer = MemoryRetrievalScorer()

    private func memory(
        _ subject: String,
        content: String,
        kind: MemoryRecord.Kind = .preference,
        daysAgo: Double = 0,
        useCount: Int = 0,
        pinned: Bool = false
    ) -> MemoryRecord {
        let stamp = now.addingTimeInterval(-daysAgo * 86_400)
        return MemoryRecord(
            kind: kind,
            subject: subject,
            content: content,
            createdAt: stamp,
            lastAccessedAt: stamp,
            useCount: useCount,
            pinned: pinned
        )
    }

    private func query(
        _ text: String? = nil,
        subject: String? = nil,
        kinds: Set<MemoryRecord.Kind> = [],
        limit: Int = 5
    ) -> MemoryQuery {
        MemoryQuery(text: text, kinds: kinds, subject: subject, limit: limit, now: now)
    }

    // MARK: - Terms

    @Test("Short and common words are not treated as signal")
    func termExtraction() {
        let terms = Set(MemoryRecord.terms(in: "The gym is on my Work calendar"))
        #expect(terms.contains("gym"))
        #expect(terms.contains("work"))
        #expect(terms.contains("calendar"))
        #expect(!terms.contains("the"))
        #expect(!terms.contains("is"))
        #expect(!terms.contains("on"))
    }

    // MARK: - Structured

    @Test("An exact subject lookup outranks everything else")
    func exactSubjectWins() throws {
        let target = memory("calendar-choice:home", content: "Home (iCloud)", daysAgo: 90)
        let recent = memory("calendar-choice:work", content: "Work (Exchange)", daysAgo: 0, useCount: 9)

        let ranked = scorer.rank([recent, target], for: query(subject: "calendar-choice:home"))
        #expect(ranked.count == 1)
        #expect(ranked[0].memory.id == target.id)
        #expect(ranked[0].structuredScore == 1)
    }

    @Test("Kind filtering excludes everything else")
    func kindFilter() {
        let preference = memory("calendar-choice:home", content: "Home (iCloud)")
        let fact = memory("gym", content: "gym is usually at six", kind: .fact)

        let ranked = scorer.rank([preference, fact], for: query("gym", kinds: [.fact]))
        #expect(ranked.map(\.memory.id) == [fact.id])
    }

    // MARK: - Relevance

    @Test("A memory sharing no terms with the query is not recalled at all")
    func irrelevantMemoriesAreDropped() {
        let unrelated = memory("dentist", content: "dentist appointments go in Personal", daysAgo: 0, useCount: 20)

        let ranked = scorer.rank([unrelated], for: query("which calendar for standup"))
        #expect(ranked.isEmpty)
    }

    @Test("More overlapping terms rank higher")
    func relevanceOrdering() throws {
        let close = memory("work calendar", content: "work meetings go in the Work calendar")
        let loose = memory("calendar", content: "calendar")

        let ranked = scorer.rank([loose, close], for: query("work meetings calendar"))
        #expect(ranked.first?.memory.id == close.id)
        #expect(try #require(ranked.first).relevanceScore > 0)
    }

    // MARK: - Recency and use

    @Test("Between equally relevant memories, the more recent one wins")
    func recencyBreaksTies() throws {
        let old = memory("gym time", content: "gym at six", daysAgo: 60)
        let fresh = memory("gym time", content: "gym at six", daysAgo: 0)

        let ranked = scorer.rank([old, fresh], for: query("gym"))
        #expect(ranked.first?.memory.id == fresh.id)
        #expect(try #require(ranked.first).recencyScore > ranked[1].recencyScore)
    }

    @Test("Recency decays by half over the configured half-life")
    func recencyHalfLife() throws {
        let weights = MemoryRetrievalScorer.Weights(recencyHalfLife: 10 * 86_400)
        let scorer = MemoryRetrievalScorer(weights: weights)
        let aged = memory("gym", content: "gym", daysAgo: 10)

        let ranked = scorer.rank([aged], for: query("gym"))
        #expect(abs(try #require(ranked.first).recencyScore - 0.5) < 0.001)
    }

    @Test("Repeated use raises the score but does not run away with it")
    func usageIsLogarithmic() throws {
        let once = memory("gym", content: "gym", useCount: 1)
        let often = memory("gym", content: "gym", useCount: 10)

        let rankedOnce = try #require(scorer.rank([once], for: query("gym")).first)
        let rankedOften = try #require(scorer.rank([often], for: query("gym")).first)

        #expect(rankedOften.usageScore > rankedOnce.usageScore)
        #expect(rankedOften.usageScore <= 1)
    }

    @Test("A pinned memory outranks an unpinned one that is otherwise stronger")
    func pinnedWins() {
        let pinned = memory("gym", content: "gym", daysAgo: 120, pinned: true)
        let fresh = memory("gym", content: "gym", daysAgo: 0, useCount: 5)

        let ranked = scorer.rank([fresh, pinned], for: query("gym"))
        #expect(ranked.first?.memory.id == pinned.id)
    }

    // MARK: - Shape of the result

    @Test("The limit is honoured")
    func limitIsApplied() {
        let memories = (0..<10).map { memory("gym \($0)", content: "gym session \($0)") }
        #expect(scorer.rank(memories, for: query("gym", limit: 3)).count == 3)
        #expect(scorer.rank(memories, for: query("gym", limit: 0)).isEmpty)
    }

    @Test("Ordering is stable across runs rather than dependent on input order")
    func orderingIsStable() {
        let memories = (0..<6).map { memory("gym \($0)", content: "gym") }
        let first = scorer.rank(memories, for: query("gym")).map(\.memory.id)
        let second = scorer.rank(memories.reversed(), for: query("gym")).map(\.memory.id)
        #expect(first == second)
    }

    @Test("With no query text, recall falls back to the most useful memories")
    func openEndedRecall() {
        let memories = [
            memory("a", content: "alpha", daysAgo: 30),
            memory("b", content: "beta", daysAgo: 1),
        ]
        let ranked = scorer.rank(memories, for: query(kinds: [.preference], limit: 2))
        #expect(ranked.count == 2)
        #expect(ranked.first?.memory.subject == "b")
    }
}

@Suite("Memory reinforcement")
struct MemoryReinforcementTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800)

    @Test("Repeating a choice strengthens it instead of duplicating it")
    func mergeStrengthens() {
        let existing = MemoryRecord(
            kind: .preference, subject: "calendar-choice:home", content: "Home (iCloud)",
            createdAt: now.addingTimeInterval(-86_400), useCount: 2
        )
        let incoming = MemoryRecord(
            kind: .preference, subject: "calendar-choice:home", content: "Home (Gmail)",
            createdAt: now
        )

        let merged = MemoryReinforcement.merge(incoming, into: existing)
        #expect(merged.id == existing.id)
        #expect(merged.createdAt == existing.createdAt)
        #expect(merged.content == "Home (Gmail)")
        #expect(merged.useCount == 3)
        #expect(merged.lastAccessedAt == now)
    }

    @Test("Pinning survives a merge")
    func pinningIsSticky() {
        let pinned = MemoryRecord(kind: .fact, subject: "s", content: "c", createdAt: now, pinned: true)
        let plain = MemoryRecord(kind: .fact, subject: "s", content: "c2", createdAt: now)

        #expect(MemoryReinforcement.merge(plain, into: pinned).pinned)
        #expect(MemoryReinforcement.merge(pinned, into: plain).pinned)
    }

    @Test("Eviction takes the least recently used and never a pinned memory")
    func eviction() {
        let stale = MemoryRecord(
            kind: .fact, subject: "stale", content: "c",
            createdAt: now, lastAccessedAt: now.addingTimeInterval(-90 * 86_400)
        )
        let pinnedStale = MemoryRecord(
            kind: .fact, subject: "pinned", content: "c",
            createdAt: now, lastAccessedAt: now.addingTimeInterval(-120 * 86_400), pinned: true
        )
        let fresh = MemoryRecord(kind: .fact, subject: "fresh", content: "c", createdAt: now)

        let evicted = MemoryReinforcement.evictionCandidates(
            from: [pinnedStale, stale, fresh],
            capacity: 2
        )
        #expect(evicted.map(\.subject) == ["stale"])
    }

    @Test("Nothing is evicted while under capacity")
    func noEvictionUnderCapacity() {
        let memories = [MemoryRecord(kind: .fact, subject: "a", content: "c", createdAt: now)]
        #expect(MemoryReinforcement.evictionCandidates(from: memories, capacity: 10).isEmpty)
    }
}
