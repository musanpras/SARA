import Foundation
import Testing
@testable import SARACore

@Suite("UserRequest")
struct UserRequestTests {
    private let now = Date(timeIntervalSince1970: 1_758_000_000)

    @Test("Normalisation trims and collapses whitespace", arguments: [
        ("  Schedule gym   tomorrow  ", "Schedule gym tomorrow"),
        ("\n\tDelete  my\tmeeting\n", "Delete my meeting"),
        ("   ", ""),
    ])
    func normalization(raw: String, expected: String) {
        let request = UserRequest(text: raw, source: .text, timestamp: now)
        #expect(request.normalizedText == expected)
    }

    @Test("Voice requests can carry recogniser confidence")
    func confidenceIsPreserved() {
        let request = UserRequest(
            text: "what's on my calendar",
            source: .voice,
            transcriptionConfidence: 0.82,
            timestamp: now
        )
        #expect(request.source == .voice)
        #expect(request.transcriptionConfidence == 0.82)
    }
}
