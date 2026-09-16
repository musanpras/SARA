import Testing
@testable import SARACore

@Suite("AssistantState")
struct AssistantStateTests {
    @Test("Busy states are the ones the user must wait on")
    func busyStates() {
        #expect(AssistantState.processing.isBusy)
        #expect(AssistantState.executing(description: "Creating event").isBusy)
        #expect(!AssistantState.idle.isBusy)
        #expect(!AssistantState.listening.isBusy)
        #expect(!AssistantState.confirming(summary: "Delete Gym?").isBusy)
    }

    @Test("Clarifying and confirming wait on the user")
    func awaitsUser() {
        #expect(AssistantState.clarifying(question: "When?").awaitsUser)
        #expect(AssistantState.confirming(summary: "Delete Gym?").awaitsUser)
        #expect(!AssistantState.processing.awaitsUser)
    }

    @Test("Input is refused only while SARA is mid-turn")
    func acceptsInput() {
        #expect(AssistantState.idle.acceptsInput)
        #expect(AssistantState.clarifying(question: "When?").acceptsInput)
        #expect(AssistantState.failed(message: "x").acceptsInput)
        #expect(!AssistantState.processing.acceptsInput)
        #expect(!AssistantState.executing(description: "x").acceptsInput)
        #expect(!AssistantState.listening.acceptsInput)
    }

    @Test("Legal transitions are permitted")
    func legalTransitions() {
        #expect(AssistantState.idle.canTransition(to: .listening))
        #expect(AssistantState.listening.canTransition(to: .processing))
        #expect(AssistantState.processing.canTransition(to: .clarifying(question: "When?")))
        #expect(AssistantState.processing.canTransition(to: .confirming(summary: "Delete?")))
        #expect(AssistantState.confirming(summary: "Delete?").canTransition(to: .executing(description: "Deleting")))
        #expect(AssistantState.executing(description: "Deleting").canTransition(to: .success(message: "Done")))
        #expect(AssistantState.success(message: "Done").canTransition(to: .idle))
    }

    @Test("Skipping the pipeline is refused")
    func illegalTransitions() {
        #expect(!AssistantState.idle.canTransition(to: .executing(description: "Deleting")))
        #expect(!AssistantState.idle.canTransition(to: .success(message: "Done")))
        #expect(!AssistantState.listening.canTransition(to: .executing(description: "x")))
        #expect(!AssistantState.executing(description: "x").canTransition(to: .idle))
    }

    @Test("Every outcome a turn can end on is reachable from processing")
    func everyTurnOutcomeIsReachable() {
        // These are exactly the states `ConversationManager` returns. A missing
        // one strands the UI mid-turn, so the rule is asserted rather than left
        // to be discovered by a user declining a deletion.
        let outcomes: [AssistantState] = [
            .idle,
            .clarifying(question: "When is it?"),
            .confirming(summary: "Delete Gym?"),
            .success(message: "Done."),
            .failed(message: "No."),
        ]
        for outcome in outcomes {
            #expect(AssistantState.processing.canTransition(to: outcome), "processing -> \(outcome)")
        }
    }

    @Test("A turn can end at idle without anything having happened")
    func idleIsAValidEnding() {
        // Declining a destructive action, and small talk, both land here.
        #expect(AssistantState.processing.canTransition(to: .idle))
        #expect(AssistantState.confirming(summary: "Delete Gym?").canTransition(to: .idle))
        #expect(AssistantState.clarifying(question: "When?").canTransition(to: .idle))
        #expect(AssistantState.listening.canTransition(to: .idle))
    }

    @Test("A pending question can be answered by voice")
    func questionsCanBeAnsweredByVoice() {
        // Holding the microphone to reply is the natural response to SARA
        // asking something aloud.
        #expect(AssistantState.confirming(summary: "Delete Gym?").canTransition(to: .listening))
        #expect(AssistantState.clarifying(question: "When?").canTransition(to: .listening))
        #expect(AssistantState.success(message: "Done.").canTransition(to: .listening))
        #expect(AssistantState.failed(message: "No.").canTransition(to: .listening))
    }

    @Test("The microphone is refused while SARA is mid-turn")
    func listeningRefusedWhileBusy() {
        #expect(!AssistantState.processing.canTransition(to: .listening))
        #expect(!AssistantState.executing(description: "x").canTransition(to: .listening))
    }

    @Test("Execution must resolve to an explicit outcome")
    func executionCannotEndQuietly() {
        let executing = AssistantState.executing(description: "Deleting")
        #expect(!executing.canTransition(to: .idle))
        #expect(executing.canTransition(to: .success(message: "Done.")))
        #expect(executing.canTransition(to: .failed(message: "No.")))
    }

    @Test("Failure is reachable from every state")
    func failureAlwaysReachable() {
        let states: [AssistantState] = [
            .idle, .listening, .processing,
            .clarifying(question: "When?"), .confirming(summary: "Delete?"),
            .executing(description: "x"), .success(message: "Done"), .failed(message: "y"),
        ]
        for state in states {
            #expect(state.canTransition(to: .failed(message: "boom")))
        }
    }
}
