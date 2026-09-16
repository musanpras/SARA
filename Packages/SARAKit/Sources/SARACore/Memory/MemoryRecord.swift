import Foundation

/// Something SARA has chosen to keep beyond the current conversation.
///
/// Memories are written deliberately, not automatically: the store holds
/// preferences, action history and session turns on its own, and a
/// `MemoryRecord` is added only when something is worth recalling later.
/// Calendar and reminder content is never copied here — EventKit stays the
/// source of truth.
public struct MemoryRecord: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// A choice the user made that hints at what they will choose again.
        case preference
        /// Something the user stated that SARA may need later.
        case fact
        /// A correction, kept so SARA can avoid repeating the mistake.
        case correction
    }

    public let id: UUID
    public let kind: Kind
    /// A short, stable key — "calendar for work events" — used for exact lookup.
    public let subject: String
    public let content: String
    /// Terms extracted at write time, so structured matching needs no scan.
    public let keywords: [String]
    public let createdAt: Date
    /// Updated whenever the memory is recalled, which feeds the recency score.
    public var lastAccessedAt: Date
    /// How often it has been recalled.
    public var useCount: Int
    /// Set when the user asked SARA to remember something explicitly. Pinned
    /// memories are never evicted and always outrank inferred ones.
    public var pinned: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        subject: String,
        content: String,
        keywords: [String]? = nil,
        createdAt: Date,
        lastAccessedAt: Date? = nil,
        useCount: Int = 0,
        pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.content = content
        self.keywords = keywords ?? MemoryRecord.terms(in: "\(subject) \(content)")
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt ?? createdAt
        self.useCount = useCount
        self.pinned = pinned
    }

    /// Lowercased, de-duplicated words worth matching on.
    ///
    /// Very short tokens and the commonest function words carry no signal and
    /// would make every memory look similar to every query.
    public static func terms(in text: String) -> [String] {
        let tokens = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        return Array(Set(tokens)).sorted()
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has",
        "was", "were", "you", "your", "are", "all", "any", "not", "its",
        "into", "onto", "about", "would", "could", "should",
    ]
}

/// What to recall, and how much of it.
public struct MemoryQuery: Sendable {
    /// Free text the memory should be relevant to.
    public var text: String?
    /// Restricts the kinds considered. Empty means all of them.
    public var kinds: Set<MemoryRecord.Kind>
    /// Exact subject to look up, which short-circuits scoring.
    public var subject: String?
    public var limit: Int
    public var now: Date

    public init(
        text: String? = nil,
        kinds: Set<MemoryRecord.Kind> = [],
        subject: String? = nil,
        limit: Int = 5,
        now: Date
    ) {
        self.text = text
        self.kinds = kinds
        self.subject = subject
        self.limit = limit
        self.now = now
    }
}

/// A memory together with why it was chosen.
///
/// The breakdown is kept rather than collapsed to one number so retrieval can
/// be reasoned about — and tested — instead of being a black box.
public struct ScoredMemory: Identifiable, Hashable, Sendable {
    public let memory: MemoryRecord
    /// Exact subject or keyword agreement, 0...1.
    public let structuredScore: Double
    /// Term overlap between the query and the memory, 0...1.
    public let relevanceScore: Double
    /// Decays with time since last use, 0...1.
    public let recencyScore: Double
    /// Grows with repeated use, 0...1.
    public let usageScore: Double
    public let total: Double

    public var id: UUID { memory.id }

    public init(
        memory: MemoryRecord,
        structuredScore: Double,
        relevanceScore: Double,
        recencyScore: Double,
        usageScore: Double,
        total: Double
    ) {
        self.memory = memory
        self.structuredScore = structuredScore
        self.relevanceScore = relevanceScore
        self.recencyScore = recencyScore
        self.usageScore = usageScore
        self.total = total
    }
}
