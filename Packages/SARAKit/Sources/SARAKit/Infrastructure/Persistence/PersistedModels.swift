import Foundation
import SARACore
import SwiftData

/// The stored shape of SARA's memory.
///
/// These types are storage detail and never leave the persistence layer —
/// everything above works with the value types in `SARACore`. Fields that are
/// enums with associated values (an undo reversal, for instance) are held as
/// encoded JSON, which keeps the schema flat and lets those types evolve
/// without a store migration.
@Model
final class PersistedPreferences {
    /// There is only ever one row; this pins it so a save updates rather than
    /// accumulates.
    #Unique<PersistedPreferences>([\.key])
    var key: String
    var payload: Data
    var updatedAt: Date

    init(key: String = PersistedPreferences.singletonKey, payload: Data, updatedAt: Date) {
        self.key = key
        self.payload = payload
        self.updatedAt = updatedAt
    }

    static let singletonKey = "preferences.v1"
}

@Model
final class PersistedHistoryEntry {
    #Unique<PersistedHistoryEntry>([\.identifier])
    var identifier: UUID
    var timestamp: Date
    var summary: String
    /// An encoded `Reversal`.
    var reversal: Data

    init(identifier: UUID, timestamp: Date, summary: String, reversal: Data) {
        self.identifier = identifier
        self.timestamp = timestamp
        self.summary = summary
        self.reversal = reversal
    }
}

@Model
final class PersistedTurn {
    #Unique<PersistedTurn>([\.identifier])
    var identifier: UUID
    var author: String
    var text: String
    var kind: String
    var timestamp: Date

    init(identifier: UUID, author: String, text: String, kind: String, timestamp: Date) {
        self.identifier = identifier
        self.author = author
        self.text = text
        self.kind = kind
        self.timestamp = timestamp
    }
}

@Model
final class PersistedMemory {
    #Unique<PersistedMemory>([\.identifier])
    var identifier: UUID
    var kind: String
    var subject: String
    var content: String
    var keywords: [String]
    var createdAt: Date
    var lastAccessedAt: Date
    var useCount: Int
    var pinned: Bool

    init(
        identifier: UUID,
        kind: String,
        subject: String,
        content: String,
        keywords: [String],
        createdAt: Date,
        lastAccessedAt: Date,
        useCount: Int,
        pinned: Bool
    ) {
        self.identifier = identifier
        self.kind = kind
        self.subject = subject
        self.content = content
        self.keywords = keywords
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.useCount = useCount
        self.pinned = pinned
    }
}

// MARK: - Mapping

extension PersistedHistoryEntry {
    convenience init(_ entry: HistoryEntry, encoder: JSONEncoder) throws {
        self.init(
            identifier: entry.id,
            timestamp: entry.timestamp,
            summary: entry.summary,
            reversal: try encoder.encode(entry.reversal)
        )
    }

    func toDomain(decoder: JSONDecoder) throws -> HistoryEntry {
        HistoryEntry(
            id: identifier,
            timestamp: timestamp,
            summary: summary,
            reversal: try decoder.decode(Reversal.self, from: reversal)
        )
    }
}

extension PersistedTurn {
    convenience init(_ message: ConversationMessage) {
        self.init(
            identifier: message.id,
            author: message.author.rawValue,
            text: message.text,
            kind: message.kind.rawValue,
            timestamp: message.timestamp
        )
    }

    /// `nil` when a stored row predates a rename of the author or kind cases;
    /// an unreadable turn is dropped rather than guessed at.
    func toDomain() -> ConversationMessage? {
        guard let author = ConversationMessage.Author(rawValue: author),
              let kind = ConversationMessage.Kind(rawValue: kind)
        else { return nil }

        return ConversationMessage(
            id: identifier,
            author: author,
            text: text,
            kind: kind,
            timestamp: timestamp
        )
    }
}

extension PersistedMemory {
    convenience init(_ memory: MemoryRecord) {
        self.init(
            identifier: memory.id,
            kind: memory.kind.rawValue,
            subject: memory.subject,
            content: memory.content,
            keywords: memory.keywords,
            createdAt: memory.createdAt,
            lastAccessedAt: memory.lastAccessedAt,
            useCount: memory.useCount,
            pinned: memory.pinned
        )
    }

    func toDomain() -> MemoryRecord? {
        guard let kind = MemoryRecord.Kind(rawValue: kind) else { return nil }
        return MemoryRecord(
            id: identifier,
            kind: kind,
            subject: subject,
            content: content,
            keywords: keywords,
            createdAt: createdAt,
            lastAccessedAt: lastAccessedAt,
            useCount: useCount,
            pinned: pinned
        )
    }

    func apply(_ memory: MemoryRecord) {
        content = memory.content
        keywords = memory.keywords
        lastAccessedAt = memory.lastAccessedAt
        useCount = memory.useCount
        pinned = memory.pinned
    }
}
