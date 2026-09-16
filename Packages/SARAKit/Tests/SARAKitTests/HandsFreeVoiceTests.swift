import Foundation
import Testing
import SARACore
import SARATesting
@testable import SARAKit

/// The hands-free loop at the view-model level: wake word starts a capture,
/// silence ends it, and a question re-opens the microphone — all without a
/// button. The pipeline is stubbed so these tests isolate microphone
/// choreography from calendar semantics.
@MainActor
@Suite("Hands-free voice loop")
struct HandsFreeVoiceTests {
    private let now = Date(timeIntervalSince1970: 1_758_000_000)

    /// Replies with a queued turn per request, recording what it was asked.
    private actor SequencedHandler: RequestHandling {
        private var turns: [AssistantTurn]
        private(set) var requests: [String] = []

        init(turns: [AssistantTurn]) { self.turns = turns }

        func handle(_ request: UserRequest) async -> AssistantTurn {
            requests.append(request.normalizedText)
            return turns.isEmpty
                ? AssistantTurn(messages: [], state: .idle)
                : turns.removeFirst()
        }
    }

    private func sara(_ text: String, _ state: AssistantState) -> AssistantTurn {
        AssistantTurn(messages: [.sara(text, at: now)], state: state)
    }

    private func makeViewModel(
        handler: SequencedHandler,
        speechTurns: [QueuedSpeechRecognizer.Turn],
        wake: ScriptedWakeWordDetector
    ) -> ConversationViewModel {
        ConversationViewModel(
            handler: handler,
            speech: QueuedSpeechRecognizer(turns: speechTurns),
            voice: SilentVoiceOutputProvider(),
            wakeWord: wake,
            configuration: .default,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    /// Drains the view model's task chain until `predicate` holds or it gives up.
    private func wait(until predicate: () async -> Bool) async {
        for _ in 0..<500 {
            if await predicate() { return }
            await Task.yield()
        }
    }

    @Test("Wake word opens a capture, and the command reaches the pipeline")
    func wakeThenCommand() async {
        let handler = SequencedHandler(turns: [
            sara("You have gym at 4 PM.", .success(message: "You have gym at 4 PM."))
        ])
        let wake = ScriptedWakeWordDetector(detectOnce: nil)
        let viewModel = makeViewModel(
            handler: handler,
            speechTurns: [.said("what's on my calendar tomorrow")],
            wake: wake
        )

        viewModel.startHandsFree()
        await wait {
            let asked = !(await handler.requests).isEmpty
            return viewModel.voiceSessionMode == .waitingForWakeWord && asked
        }

        #expect(await handler.requests == ["what's on my calendar tomorrow"])
        // The turn finished, so the microphone is back on the wake word.
        #expect(viewModel.voiceSessionMode == .waitingForWakeWord)
    }

    @Test("A wake word spoken with the command in one breath skips the extra capture")
    func trailingCommandUsedDirectly() async {
        let handler = SequencedHandler(turns: [
            sara("Done.", .success(message: "Done."))
        ])
        let speech = QueuedSpeechRecognizer(turns: [])
        let wake = ScriptedWakeWordDetector(detectOnce: "delete gym tomorrow")
        let viewModel = ConversationViewModel(
            handler: handler,
            speech: speech,
            voice: SilentVoiceOutputProvider(),
            wakeWord: wake,
            configuration: .default,
            dateProvider: FixedDateProvider(now: now)
        )

        viewModel.startHandsFree()
        await wait {
            let asked = !(await handler.requests).isEmpty
            return asked
        }

        #expect(await handler.requests == ["delete gym tomorrow"])
        // The command came from the wake phrase; the recogniser was never opened.
        #expect(await speech.startCount == 0)
    }

    @Test("A clarification re-opens the microphone and the answer is processed")
    func followUpListensAgain() async {
        let handler = SequencedHandler(turns: [
            sara("What time?", .clarifying(question: "What time?")),
            sara("Done.", .success(message: "Done."))
        ])
        let wake = ScriptedWakeWordDetector(detectOnce: nil)
        let viewModel = makeViewModel(
            handler: handler,
            speechTurns: [.said("schedule a meeting tomorrow"), .said("3 PM")],
            wake: wake
        )

        viewModel.startHandsFree()
        await wait {
            let two = (await handler.requests).count == 2
            return two && viewModel.voiceSessionMode == .waitingForWakeWord
        }

        // Both the command and the follow-up answer went through, with no button
        // press between them.
        #expect(await handler.requests == ["schedule a meeting tomorrow", "3 PM"])
        #expect(viewModel.voiceSessionMode == .waitingForWakeWord)
    }

    @Test("A confirmation re-opens the microphone; \"no\" is forwarded and the loop resets")
    func confirmationListensAgain() async {
        let handler = SequencedHandler(turns: [
            sara("Delete Gym tomorrow at 4 PM?", .confirming(summary: "Delete Gym?")),
            sara("Okay.", .idle)
        ])
        let wake = ScriptedWakeWordDetector(detectOnce: nil)
        let viewModel = makeViewModel(
            handler: handler,
            speechTurns: [.said("delete gym tomorrow"), .said("no")],
            wake: wake
        )

        viewModel.startHandsFree()
        await wait {
            let two = (await handler.requests).count == 2
            return two && viewModel.voiceSessionMode == .waitingForWakeWord
        }

        #expect(await handler.requests == ["delete gym tomorrow", "no"])
        #expect(viewModel.voiceSessionMode == .waitingForWakeWord)
    }

    @Test("Stopping hands-free releases the microphone and the wake engine")
    func stopHandsFree() async {
        let handler = SequencedHandler(turns: [])
        let wake = ScriptedWakeWordDetector(events: [])   // never fires
        let viewModel = makeViewModel(handler: handler, speechTurns: [], wake: wake)

        viewModel.startHandsFree()
        await wait { viewModel.voiceSessionMode == .waitingForWakeWord }

        viewModel.stopHandsFree()
        await wait {
            let stopped = await wake.stopCount >= 1
            return viewModel.voiceSessionMode == .off && stopped
        }
        #expect(viewModel.voiceSessionMode == .off)
        #expect(await wake.stopCount >= 1)
    }

    @Test("The wake phrase never becomes part of the command")
    func wakePhraseStrippedFromCommand() async {
        let handler = SequencedHandler(turns: [
            sara("Done.", .success(message: "Done."))
        ])
        let wake = ScriptedWakeWordDetector(detectOnce: nil)
        // The recogniser mis-captures the phrase into the command audio.
        let viewModel = makeViewModel(
            handler: handler,
            speechTurns: [.said("Hey SARA schedule gym tomorrow")],
            wake: wake
        )

        viewModel.startHandsFree()
        await wait {
            let asked = !(await handler.requests).isEmpty
            return asked
        }

        #expect(await handler.requests == ["schedule gym tomorrow"])
    }
}
