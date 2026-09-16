import Foundation
import Testing
import SARACore
import SARATesting
@testable import SARAKit

/// Replies with a scripted turn per request, so a multi-step exchange can be
/// driven through the view model.
private struct ScriptedHandler: RequestHandling {
    let turns: [AssistantTurn]
    let cursor: Cursor

    final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let value = index
            index += 1
            return value
        }
    }

    func handle(_ request: UserRequest) async -> AssistantTurn {
        let index = cursor.next()
        return turns[min(index, turns.count - 1)]
    }
}

@MainActor
@Suite("Declining a destructive action")
struct DeclineConfirmationTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800)

    private func makeViewModel(
        turns: [AssistantTurn],
        speech: ScriptedSpeechRecognizer? = nil
    ) -> ConversationViewModel {
        ConversationViewModel(
            handler: ScriptedHandler(turns: turns, cursor: ScriptedHandler.Cursor()),
            speech: speech,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    @Test("Saying no to a deletion returns SARA to idle and accepts input again")
    func decliningLeavesSaraUsable() async {
        let viewModel = makeViewModel(turns: [
            AssistantTurn(
                messages: [.sara("I found Gym tomorrow at 4 PM. Do you want me to delete it?",
                                 kind: .confirmation, at: now)],
                state: .confirming(summary: "Delete Gym tomorrow at 4 PM")
            ),
            AssistantTurn(
                messages: [.sara("Alright, I've left it as it is.", at: now)],
                state: .idle
            ),
        ])

        await viewModel.submit(text: "delete gym tomorrow", source: .text, confidence: nil)
        #expect(viewModel.state == .confirming(summary: "Delete Gym tomorrow at 4 PM"))

        await viewModel.submit(text: "no", source: .text, confidence: nil)

        #expect(viewModel.state == .idle)
        #expect(viewModel.canSubmit)
        #expect(viewModel.transcript.lastSaraMessage?.text == "Alright, I've left it as it is.")
    }

    @Test("Small talk also ends a turn at idle")
    func smallTalkReturnsToIdle() async {
        let viewModel = makeViewModel(turns: [
            AssistantTurn(messages: [.sara("Good morning.", at: now)], state: .idle)
        ])

        await viewModel.submit(text: "good morning", source: .text, confidence: nil)

        #expect(viewModel.state == .idle)
        #expect(viewModel.canSubmit)
    }

    @Test("A confirmation can be answered by voice")
    func confirmationAnsweredByVoice() async {
        let recognizer = ScriptedSpeechRecognizer(finalTranscript: "no")
        let viewModel = makeViewModel(
            turns: [
                AssistantTurn(
                    messages: [.sara("Delete it?", kind: .confirmation, at: now)],
                    state: .confirming(summary: "Delete Gym")
                ),
                AssistantTurn(
                    messages: [.sara("Alright, I've left it as it is.", at: now)],
                    state: .idle
                ),
            ],
            speech: recognizer
        )

        await viewModel.submit(text: "delete gym tomorrow", source: .text, confidence: nil)
        #expect(viewModel.state == .confirming(summary: "Delete Gym"))

        // Holding the microphone while a confirmation is pending must work: it
        // is the natural way to answer a spoken question.
        viewModel.beginListening()
        #expect(viewModel.state == .listening)

        viewModel.endListening()
        for _ in 0..<8 { await Task.yield() }

        #expect(viewModel.state == .idle)
    }
}
