import Foundation
import Testing
import SARACore
import SARATesting
@testable import SARAKit

@Suite("Execution progress")
struct ExecutionProgressTests {
    private let base = Date(timeIntervalSince1970: 1_789_516_800)

    private func event(_ title: String) -> CalendarEvent {
        CalendarEvent(
            id: EventIdentifier("e"),
            title: title,
            start: base,
            end: base.addingTimeInterval(3600),
            calendarID: CalendarIdentifier("c"),
            calendarTitle: "Personal"
        )
    }

    private func reminder(_ title: String) -> Reminder {
        Reminder(
            id: ReminderIdentifier("r"),
            title: title,
            listID: CalendarIdentifier("l"),
            listTitle: "Reminders"
        )
    }

    @Test("Each operation names what it is doing")
    func operationDescriptions() {
        let draft = CalendarEventDraft(title: "Gym", start: base, end: base.addingTimeInterval(3600))

        #expect(ExecutableOperation.createEvent(draft).progressDescription == "Creating Gym")
        #expect(
            ExecutableOperation
                .updateEvent(target: event("Gym"), changes: CalendarEventChanges(), span: .thisEvent)
                .progressDescription == "Updating Gym"
        )
        #expect(
            ExecutableOperation.deleteEvent(target: event("Gym"), span: .thisEvent)
                .progressDescription == "Deleting Gym"
        )
        #expect(
            ExecutableOperation.createReminder(ReminderDraft(title: "Call John"))
                .progressDescription == "Adding Call John"
        )
        #expect(
            ExecutableOperation.deleteReminder(target: reminder("Call John"))
                .progressDescription == "Deleting Call John"
        )
        #expect(
            ExecutableOperation.searchEvents(EventSearchQuery(interval: DateInterval()))
                .progressDescription == "Checking your calendar"
        )
        #expect(
            ExecutableOperation.searchReminders(ReminderSearchQuery())
                .progressDescription == "Checking your reminders"
        )
        #expect(ExecutableOperation.undoLastAction.progressDescription == "Undoing that")
    }

    @Test("A single-action plan uses that action's wording; several are summarised")
    func planDescriptions() {
        let draft = CalendarEventDraft(title: "Gym", start: base, end: base.addingTimeInterval(3600))
        let create = ExecutableAction(id: "a", operation: .createEvent(draft))
        let remind = ExecutableAction(id: "b", operation: .createReminder(ReminderDraft(title: "Kit")))

        let single = ExecutablePlan(planID: UUID(), requestID: UUID(), actions: [create], waves: [["a"]])
        #expect(single.progressDescription == "Creating Gym")

        let several = ExecutablePlan(
            planID: UUID(), requestID: UUID(),
            actions: [create, remind], waves: [["a", "b"]]
        )
        #expect(several.progressDescription == "Making 2 changes")

        let empty = ExecutablePlan(planID: UUID(), requestID: UUID(), actions: [], waves: [])
        #expect(empty.progressDescription == "Working")
    }
}

/// Collects what the pipeline announced, with no timing involved.
private actor ProgressRecorder: TurnProgressObserving {
    private(set) var announcements: [String] = []

    func executionDidBegin(_ description: String) async {
        announcements.append(description)
    }
}

@Suite("Progress reporting")
struct ProgressReportingTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)

    private func makeManager(
        calendars: InMemoryCalendarService = InMemoryCalendarService(),
        reminders: InMemoryReminderService = InMemoryReminderService()
    ) -> ConversationManager {
        SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: reminders,
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now)
        ).manager
    }

    @discardableResult
    private func say(
        _ text: String,
        to manager: ConversationManager,
        progress: ProgressRecorder?
    ) async -> AssistantTurn {
        await manager.handle(
            UserRequest(text: text, source: .text, timestamp: now),
            progress: progress
        )
    }

    @Test("Execution is announced exactly once, before the work runs")
    func announcedOnce() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say("Schedule gym tomorrow at 4 PM", to: manager, progress: recorder)
        #expect(await recorder.announcements == ["Creating gym"])
    }

    @Test("Nothing is announced for a turn that only asks a question")
    func nothingAnnouncedForQuestions() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say("Schedule dentist tomorrow", to: manager, progress: recorder)
        #expect(await recorder.announcements.isEmpty)

        await say("Delete gym tomorrow", to: manager, progress: recorder)
        #expect(await recorder.announcements.isEmpty)
    }

    @Test("A destructive action is announced only after it is confirmed")
    func announcedAfterConfirmation() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say("Schedule gym tomorrow at 4 PM", to: manager, progress: recorder)
        await say("Delete gym tomorrow", to: manager, progress: recorder)
        #expect(await recorder.announcements == ["Creating gym"])

        await say("yes", to: manager, progress: recorder)
        #expect(await recorder.announcements == ["Creating gym", "Deleting gym"])
    }

    @Test("Declining announces nothing further")
    func declineAnnouncesNothing() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say("Schedule gym tomorrow at 4 PM", to: manager, progress: recorder)
        await say("Delete gym tomorrow", to: manager, progress: recorder)
        await say("no", to: manager, progress: recorder)

        #expect(await recorder.announcements == ["Creating gym"])
    }

    @Test("Answering a clarification announces the work it unblocked")
    func clarificationThenExecution() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say("Schedule dentist tomorrow", to: manager, progress: recorder)
        await say("at 3 pm", to: manager, progress: recorder)

        #expect(await recorder.announcements == ["Creating dentist"])
    }

    @Test("A multi-action turn is announced as one summary")
    func multiActionSummary() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say(
            "Schedule gym tomorrow at 4 PM and remind me to bring my kit tomorrow at 3 PM",
            to: manager,
            progress: recorder
        )
        #expect(await recorder.announcements == ["Making 2 changes"])
    }

    @Test("Undo announces itself")
    func undoAnnounced() async {
        let recorder = ProgressRecorder()
        let manager = makeManager()

        await say("Schedule gym tomorrow at 4 PM", to: manager, progress: recorder)
        await say("Undo that", to: manager, progress: recorder)

        #expect(await recorder.announcements == ["Creating gym", "Undoing that"])
    }
}

/// Records the states the UI passed through, so ordering can be asserted
/// rather than inferred from the final value.
@MainActor
private final class StateRecorder {
    private(set) var states: [AssistantState] = []
    func record(_ state: AssistantState) { states.append(state) }
}

@MainActor
@Suite("Executing state in the UI")
struct ExecutingStateTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800)

    private func makeViewModel(
        calendars: InMemoryCalendarService = InMemoryCalendarService(),
        reminders: InMemoryReminderService = InMemoryReminderService()
    ) -> ConversationViewModel {
        let assembled = SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: reminders,
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now)
        )
        return ConversationViewModel(
            handler: assembled.manager,
            dateProvider: FixedDateProvider(now: now)
        )
    }

    /// Samples the view model's state while a turn is in flight.
    private func observing(
        _ viewModel: ConversationViewModel,
        while work: () async -> Void
    ) async -> [AssistantState] {
        let recorder = StateRecorder()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                recorder.record(viewModel.state)
                await Task.yield()
            }
        }
        await work()
        sampler.cancel()

        // Collapse runs so the sequence reads as transitions, not samples.
        return recorder.states.reduce(into: [AssistantState]()) { result, state in
            if result.last != state { result.append(state) }
        }
    }

    @Test("Creating an event passes through executing on its way to success")
    func createShowsExecuting() async {
        let viewModel = makeViewModel()

        let states = await observing(viewModel) {
            await viewModel.submit(
                text: "Schedule gym tomorrow at 4 PM",
                source: .text,
                confidence: nil
            )
        }

        #expect(states.contains(.executing(description: "Creating gym")))
        if let executingIndex = states.firstIndex(of: .executing(description: "Creating gym")),
           let processingIndex = states.firstIndex(of: .processing) {
            #expect(processingIndex < executingIndex)
        } else {
            Issue.record("Expected both processing and executing, got \(states)")
        }
        guard case .success = viewModel.state else {
            Issue.record("Expected success, got \(viewModel.state)")
            return
        }
    }

    @Test("A confirmed deletion shows what is being deleted")
    func deleteShowsExecuting() async {
        let calendars = InMemoryCalendarService()
        let viewModel = makeViewModel(calendars: calendars)

        await viewModel.submit(text: "Schedule gym tomorrow at 4 PM", source: .text, confidence: nil)
        await viewModel.submit(text: "Delete gym tomorrow", source: .text, confidence: nil)
        guard case .confirming = viewModel.state else {
            Issue.record("Expected a confirmation, got \(viewModel.state)")
            return
        }

        let states = await observing(viewModel) {
            await viewModel.submit(text: "yes", source: .text, confidence: nil)
        }

        #expect(states.contains(.executing(description: "Deleting gym")))
        #expect(await calendars.allEvents.isEmpty)
    }

    @Test("A turn that only asks a question never claims to be executing")
    func clarificationDoesNotExecute() async {
        let viewModel = makeViewModel()

        let states = await observing(viewModel) {
            await viewModel.submit(text: "Schedule dentist tomorrow", source: .text, confidence: nil)
        }

        #expect(!states.contains { $0.isExecuting })
        #expect(viewModel.state == .clarifying(question: "What time should I schedule it?"))
    }

    @Test("Declining still never executes")
    func declineDoesNotExecute() async {
        let calendars = InMemoryCalendarService()
        let viewModel = makeViewModel(calendars: calendars)

        await viewModel.submit(text: "Schedule gym tomorrow at 4 PM", source: .text, confidence: nil)
        await viewModel.submit(text: "Delete gym tomorrow", source: .text, confidence: nil)

        let states = await observing(viewModel) {
            await viewModel.submit(text: "no", source: .text, confidence: nil)
        }

        #expect(!states.contains { $0.isExecuting })
        #expect(viewModel.state == .idle)
        #expect(await calendars.deleteCount == 0)
    }

    @Test("A handler with no execution phase still works")
    func handlerWithoutProgressStillWorks() async {
        // Proves the protocol default: a conformer implementing only
        // `handle(_:)` is unaffected by the progress channel.
        struct PlainHandler: RequestHandling {
            let now: Date
            func handle(_ request: UserRequest) async -> AssistantTurn {
                AssistantTurn(messages: [.sara("Hello.", at: now)], state: .idle)
            }
        }

        let viewModel = ConversationViewModel(
            handler: PlainHandler(now: now),
            dateProvider: FixedDateProvider(now: now)
        )
        await viewModel.submit(text: "hello", source: .text, confidence: nil)

        #expect(viewModel.state == .idle)
        #expect(viewModel.transcript.lastSaraMessage?.text == "Hello.")
    }
}
