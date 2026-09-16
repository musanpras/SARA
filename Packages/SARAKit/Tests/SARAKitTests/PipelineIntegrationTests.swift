import Foundation
import Testing
import SARACore
import SARATesting

/// End-to-end coverage of the commands in the definition of done, exercised
/// through the real pipeline with in-memory EventKit stand-ins.
///
/// Anchored to Wednesday 16 September 2026, 10:00 UTC.
@Suite("Pipeline")
struct PipelineIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)

    private struct Harness {
        let manager: ConversationManager
        let calendars: InMemoryCalendarService
        let reminders: InMemoryReminderService
        let history: ActionHistory
    }

    private func makeHarness(
        preferences: SARAPreferences = .default,
        calendarStatus: PermissionStatus = .authorized
    ) -> Harness {
        let calendars = InMemoryCalendarService(status: calendarStatus)
        let reminders = InMemoryReminderService()
        let result = SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: reminders,
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now),
            preferences: preferences
        )
        return Harness(
            manager: result.manager,
            calendars: calendars,
            reminders: reminders,
            history: result.history
        )
    }

    @discardableResult
    private func say(_ text: String, to harness: Harness) async -> AssistantTurn {
        await harness.manager.handle(UserRequest(text: text, source: .text, timestamp: now))
    }

    private func reply(_ turn: AssistantTurn) -> String {
        turn.messages.map(\.text).joined(separator: "\n")
    }

    private func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Definition of done

    @Test("\"Schedule gym tomorrow at 4 PM for one hour\" creates a verified event")
    func scheduleGym() async throws {
        let harness = makeHarness()
        let turn = await say("Schedule gym tomorrow at 4 PM for one hour", to: harness)

        #expect(turn.state == .success(message: reply(turn)))
        #expect(reply(turn).hasPrefix("Done."))
        #expect(reply(turn).contains("tomorrow at 4 PM"))

        let stored = await harness.calendars.allEvents
        #expect(stored.count == 1)
        #expect(stored[0].title == "gym")
        #expect(iso(stored[0].start) == "2026-09-17 16:00")
        #expect(iso(stored[0].end) == "2026-09-17 17:00")
    }

    @Test("A missing time is asked about and the answer completes the event")
    func clarifyThenCreate() async throws {
        let harness = makeHarness()

        let question = await say("Schedule dentist tomorrow", to: harness)
        #expect(question.state == .clarifying(question: "What time should I schedule it?"))
        #expect(await harness.calendars.createCount == 0)

        let done = await say("at 3 pm", to: harness)
        #expect(done.state.isSuccess)

        let stored = await harness.calendars.allEvents
        #expect(stored.count == 1)
        #expect(iso(stored[0].start) == "2026-09-17 15:00")
    }

    @Test("\"What's on my calendar tomorrow?\" reads back what is there")
    func searchCalendar() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)

        let turn = await say("What's on my calendar tomorrow?", to: harness)
        #expect(reply(turn).contains("gym"))
        #expect(reply(turn).contains("tomorrow at 4 PM"))
    }

    @Test("An empty day is reported as empty, not invented")
    func searchEmptyDay() async {
        let harness = makeHarness()
        let turn = await say("What's on my calendar tomorrow?", to: harness)
        #expect(reply(turn) == "Nothing scheduled.")
    }

    @Test("\"Move gym tomorrow to 6 PM\" moves it and keeps its length")
    func moveEvent() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM for 90 minutes", to: harness)

        let turn = await say("Move gym tomorrow to 6 PM", to: harness)
        #expect(turn.state.isSuccess)

        let stored = await harness.calendars.allEvents
        #expect(iso(stored[0].start) == "2026-09-17 18:00")
        #expect(iso(stored[0].end) == "2026-09-17 19:30")
    }

    @Test("\"Delete gym tomorrow\" confirms first and only deletes on agreement")
    func deleteWithConfirmation() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)

        let question = await say("Delete gym tomorrow", to: harness)
        guard case .confirming = question.state else {
            Issue.record("Expected a confirmation, got \(question.state)")
            return
        }
        #expect(reply(question).contains("Do you want me to delete it?"))
        #expect(await harness.calendars.deleteCount == 0)

        let done = await say("yes", to: harness)
        #expect(done.state.isSuccess)
        #expect(await harness.calendars.allEvents.isEmpty)
    }

    @Test("Declining a deletion leaves the event alone")
    func declineDeletion() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)
        await say("Delete gym tomorrow", to: harness)

        let turn = await say("no", to: harness)
        #expect(turn.state == .idle)
        #expect(await harness.calendars.allEvents.count == 1)
        #expect(await harness.calendars.deleteCount == 0)
    }

    @Test("Three matching events produce one question, and the answer picks one")
    func ambiguousDeletion() async throws {
        let harness = makeHarness()
        await say("Schedule Team Meeting today at 2 PM", to: harness)
        await say("Schedule Team Meeting tomorrow at 10 AM", to: harness)
        await say("Schedule Team Meeting on Friday at 3 PM", to: harness)

        let question = await say("Delete my Team Meeting", to: harness)
        guard case .clarifying = question.state else {
            Issue.record("Expected a clarification, got \(question.state)")
            return
        }
        #expect(reply(question).contains("Team Meeting today at 2 PM"))
        #expect(reply(question).contains("Team Meeting tomorrow at 10 AM"))
        #expect(reply(question).contains("Team Meeting Friday at 3 PM"))

        let confirm = await say("the second one", to: harness)
        guard case .confirming = confirm.state else {
            Issue.record("Expected a confirmation, got \(confirm.state)")
            return
        }
        #expect(reply(confirm).contains("tomorrow at 10 AM"))

        await say("yes", to: harness)
        let remaining = await harness.calendars.allEvents.map(\.title)
        #expect(remaining.count == 2)
        let starts = await harness.calendars.allEvents.map { iso($0.start) }
        #expect(!starts.contains("2026-09-17 10:00"))
    }

    @Test("\"Remind me to submit my assignment tomorrow at 8 PM\" creates a reminder")
    func createReminder() async throws {
        let harness = makeHarness()
        let turn = await say("Remind me to submit my assignment tomorrow at 8 PM", to: harness)
        #expect(turn.state.isSuccess)

        let stored = await harness.reminders.allReminders
        #expect(stored.count == 1)
        #expect(stored[0].title == "submit my assignment")
        #expect(iso(try #require(stored[0].dueDate)) == "2026-09-17 20:00")
    }

    @Test("\"What do I need to do tomorrow?\" answers across both sources")
    func unifiedQuery() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)
        await say("Remind me to submit my assignment tomorrow at 8 PM", to: harness)

        let turn = await say("What do I need to do tomorrow?", to: harness)
        let text = reply(turn)
        #expect(text.contains("gym"))
        #expect(text.contains("submit my assignment"))
        // Events and reminders stay distinguishable.
        #expect(text.contains("event"))
        #expect(text.contains("reminder"))
    }

    @Test("A conflicting time asks before scheduling over a commitment")
    func conflictAsks() async throws {
        let harness = makeHarness()
        await say("Schedule Team Meeting tomorrow at 2 PM for one hour", to: harness)

        let question = await say("Schedule gym tomorrow at 2 PM", to: harness)
        guard case .confirming = question.state else {
            Issue.record("Expected a conflict confirmation, got \(question.state)")
            return
        }
        #expect(reply(question).contains("Team Meeting"))
        #expect(await harness.calendars.allEvents.count == 1)

        await say("yes", to: harness)
        #expect(await harness.calendars.allEvents.count == 2)
    }

    @Test("\"Actually, make that 5 PM\" revises rather than duplicating")
    func correctionAfterCreation() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)

        let turn = await say("Actually, make that 5 PM", to: harness)
        #expect(turn.state.isSuccess)

        let stored = await harness.calendars.allEvents
        #expect(stored.count == 1)
        #expect(iso(stored[0].start) == "2026-09-17 17:00")
    }

    @Test("\"Undo that\" reverses the last action")
    func undo() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)
        #expect(await harness.calendars.allEvents.count == 1)

        let turn = await say("Undo that", to: harness)
        #expect(turn.state.isSuccess)
        #expect(reply(turn).contains("undone"))
        #expect(await harness.calendars.allEvents.isEmpty)
    }

    @Test("Undo with nothing to reverse says so")
    func undoNothing() async {
        let harness = makeHarness()
        let turn = await say("Undo that", to: harness)
        #expect(reply(turn) == "There's nothing for me to undo.")
    }

    @Test("A multi-action command creates both, in order")
    func multiAction() async throws {
        let harness = makeHarness()
        let turn = await say(
            "Schedule gym tomorrow at 4 PM and remind me to bring my kit tomorrow at 3 PM",
            to: harness
        )
        #expect(turn.state.isSuccess)
        #expect(await harness.calendars.allEvents.count == 1)
        #expect(await harness.reminders.allReminders.count == 1)
    }

    @Test("A failing step is reported as failed, not rounded up to done")
    func partialFailureIsHonest() async throws {
        let harness = makeHarness()
        await harness.reminders.setFailure(.underlying("the store is unavailable"))

        let turn = await say(
            "Schedule gym tomorrow at 4 PM and remind me to bring my kit tomorrow at 3 PM",
            to: harness
        )

        #expect(!turn.state.isSuccess)
        let text = reply(turn)
        #expect(text.localizedCaseInsensitiveContains("gym is on your calendar"))
        #expect(text.contains("The reminders operation failed"))
        #expect(await harness.calendars.allEvents.count == 1)
        #expect(await harness.reminders.allReminders.isEmpty)
    }

    @Test("\"Delete the reminder to X\" finds the reminder rather than nothing")
    func deleteReminderByName() async throws {
        let harness = makeHarness()
        await say("Remind me to call John tomorrow at 9 AM", to: harness)

        let question = await say("Delete the reminder to call John", to: harness)
        guard case .confirming = question.state else {
            Issue.record("Expected a confirmation, got \(question.state)")
            return
        }
        #expect(reply(question).contains("call John"))

        await say("yes", to: harness)
        #expect(await harness.reminders.allReminders.isEmpty)
    }

    @Test("Declining a reminder deletion leaves it alone and SARA usable")
    func declineReminderDeletion() async throws {
        let harness = makeHarness()
        await say("Remind me to call John tomorrow at 9 AM", to: harness)
        await say("Delete the reminder to call John", to: harness)

        let turn = await say("no", to: harness)
        #expect(turn.state == .idle)
        #expect(await harness.reminders.allReminders.count == 1)
        #expect(await harness.reminders.deleteCount == 0)

        // The next request must still be accepted.
        let after = await say("What do I need to do tomorrow?", to: harness)
        #expect(reply(after).contains("call John"))
    }

    @Test("Denied calendar access is explained rather than hidden")
    func deniedPermission() async {
        let harness = makeHarness(calendarStatus: .denied)
        let turn = await say("Schedule gym tomorrow at 4 PM", to: harness)

        #expect(!turn.state.isSuccess)
        #expect(reply(turn).contains("Settings"))
        #expect(await harness.calendars.createCount == 0)
    }

    @Test("Phrasing SARA cannot interpret is admitted, not guessed at")
    func unparseableRequest() async {
        let harness = makeHarness()
        let turn = await say("What's the weather like in Jakarta?", to: harness)
        #expect(!turn.state.isSuccess)
        #expect(await harness.calendars.createCount == 0)
    }
}

private extension AssistantState {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
