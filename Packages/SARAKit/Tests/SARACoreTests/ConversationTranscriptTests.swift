import Foundation
import Testing
@testable import SARACore

@Suite("ConversationTranscript")
struct ConversationTranscriptTests {
    private let now = Date(timeIntervalSince1970: 1_758_000_000)

    @Test("Appending keeps order")
    func ordering() {
        var transcript = ConversationTranscript()
        transcript.append(.user("first", at: now))
        transcript.append(.sara("second", at: now))

        #expect(transcript.messages.map(\.text) == ["first", "second"])
        #expect(transcript.lastUserMessage?.text == "first")
        #expect(transcript.lastSaraMessage?.text == "second")
    }

    @Test("Capacity evicts the oldest messages")
    func capacityEviction() {
        var transcript = ConversationTranscript(capacity: 3)
        for index in 0..<5 {
            transcript.append(.user("m\(index)", at: now))
        }

        #expect(transcript.messages.count == 3)
        #expect(transcript.messages.map(\.text) == ["m2", "m3", "m4"])
    }

    @Test("Initialising over capacity truncates to the newest messages")
    func initTruncates() {
        let seed = (0..<5).map { ConversationMessage.user("m\($0)", at: now) }
        let transcript = ConversationTranscript(messages: seed, capacity: 2)

        #expect(transcript.messages.map(\.text) == ["m3", "m4"])
    }

    @Test("Recent window is clamped and oldest-first")
    func recentWindow() {
        var transcript = ConversationTranscript()
        for index in 0..<4 {
            transcript.append(.user("m\(index)", at: now))
        }

        #expect(transcript.recent(2).map(\.text) == ["m2", "m3"])
        #expect(transcript.recent(0).isEmpty)
        #expect(transcript.recent(99).count == 4)
    }
}
