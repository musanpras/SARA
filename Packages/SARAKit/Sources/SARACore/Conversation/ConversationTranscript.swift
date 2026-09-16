import Foundation

/// Ordered, bounded record of the current conversation.
///
/// The transcript is deliberately capped: SARA's working context is the recent
/// turn window, and long-term recall is the `MemoryEngine`'s job rather than an
/// ever-growing array held in memory.
public struct ConversationTranscript: Equatable, Sendable {
    public private(set) var messages: [ConversationMessage]
    public let capacity: Int

    public init(messages: [ConversationMessage] = [], capacity: Int = 200) {
        precondition(capacity > 0, "Transcript capacity must be positive")
        self.capacity = capacity
        self.messages = Array(messages.suffix(capacity))
    }

    public var isEmpty: Bool { messages.isEmpty }

    public var lastUserMessage: ConversationMessage? {
        messages.last { $0.author == .user }
    }

    public var lastSaraMessage: ConversationMessage? {
        messages.last { $0.author == .sara }
    }

    public mutating func append(_ message: ConversationMessage) {
        messages.append(message)
        if messages.count > capacity {
            messages.removeFirst(messages.count - capacity)
        }
    }

    /// The most recent `count` messages, oldest first.
    public func recent(_ count: Int) -> [ConversationMessage] {
        guard count > 0 else { return [] }
        return Array(messages.suffix(count))
    }

    public mutating func removeAll() {
        messages.removeAll()
    }
}
