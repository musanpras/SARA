import Testing
@testable import SARACore

@Suite("Wake word matching")
struct WakeWordTests {
    private let matcher = WakeWordMatcher(phrase: "Hey SARA")

    @Test("Detects the phrase regardless of case and punctuation")
    func detectsNormalized() {
        #expect(matcher.match(in: "Hey SARA") != nil)
        #expect(matcher.match(in: "hey sara") != nil)
        #expect(matcher.match(in: "Hey, SARA!") != nil)
    }

    @Test("A command spoken in the same breath comes back as the trailing command")
    func trailingCommand() {
        let match = matcher.match(in: "Hey SARA, schedule gym tomorrow at 4 PM")
        #expect(match?.trailingCommand == "schedule gym tomorrow at 4 pm")
    }

    @Test("The phrase alone has no trailing command")
    func phraseAlone() {
        #expect(matcher.match(in: "Hey SARA")?.trailingCommand == nil)
    }

    @Test("Common mis-hearings of the name still trigger")
    func fuzzyName() {
        // Apple's recogniser writes "SARA" all sorts of ways.
        #expect(matcher.match(in: "Hey Sarah") != nil)
        #expect(matcher.match(in: "hey sara") != nil)
        #expect(matcher.match(in: "Hey Zara") != nil)
        #expect(matcher.match(in: "Hey Sarah, delete gym")?.trailingCommand == "delete gym")
    }

    @Test("Text without the phrase does not match")
    func noMatch() {
        #expect(matcher.match(in: "schedule gym tomorrow") == nil)
        #expect(matcher.match(in: "hey there") == nil)
        // The leading word still has to be right — a lone near-name is not enough.
        #expect(matcher.match(in: "the sarah movie") == nil)
    }

    @Test("Stripping removes a leaked wake phrase so the pipeline never sees it")
    func stripping() {
        #expect(matcher.stripping(from: "Hey SARA schedule gym") == "schedule gym")
        // No phrase present: text is returned untouched.
        #expect(matcher.stripping(from: "schedule gym") == "schedule gym")
        // Only the phrase: nothing left to act on.
        #expect(matcher.stripping(from: "Hey SARA") == "")
    }

    @Test("The last occurrence wins when the phrase repeats")
    func lastOccurrenceWins() {
        let match = matcher.match(in: "Hey SARA Hey SARA delete gym")
        #expect(match?.trailingCommand == "delete gym")
    }
}

@Suite("Voice interaction policy")
struct VoiceInteractionPolicyTests {
    private let policy = VoiceInteractionPolicy()

    @Test("A question re-opens the microphone")
    func questionsListenAgain() {
        #expect(policy.followUp(after: .clarifying(question: "What time?")) == .listenAgain)
        #expect(policy.followUp(after: .confirming(summary: "Delete Gym?")) == .listenAgain)
    }

    @Test("A finished or failed turn returns to the wake word")
    func terminalReturnsToWakeWord() {
        #expect(policy.followUp(after: .success(message: "Done")) == .returnToWakeWord)
        #expect(policy.followUp(after: .idle) == .returnToWakeWord)
        #expect(policy.followUp(after: .failed(message: "Oops")) == .returnToWakeWord)
    }
}
