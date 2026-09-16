import Foundation

/// One rendered line of conversation.
///
/// Messages are presentation records only. They are never the source of truth
/// for a Calendar or Reminder record — EventKit holds that.
public struct ConversationMessage: Identifiable, Equatable, Sendable, Codable {
    public enum Author: String, Equatable, Sendable, Codable {
        case user
        case sara
    }

    /// Drives tone and styling. Destructive and failure messages are visually
    /// distinct so the user is never surprised by an irreversible action.
    public enum Kind: String, Equatable, Sendable, Codable {
        case standard
        case clarification
        case confirmation
        case success
        case failure
    }

    public let id: UUID
    public let author: Author
    public let text: String
    public let kind: Kind
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        author: Author,
        text: String,
        kind: Kind = .standard,
        timestamp: Date
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.kind = kind
        self.timestamp = timestamp
    }

    public static func user(_ text: String, at timestamp: Date) -> ConversationMessage {
        ConversationMessage(author: .user, text: text, timestamp: timestamp)
    }

    public static func sara(
        _ text: String,
        kind: Kind = .standard,
        at timestamp: Date
    ) -> ConversationMessage {
        ConversationMessage(author: .sara, text: text, kind: kind, timestamp: timestamp)
    }
}
