import Foundation
import Testing
import SARACore
import SARATesting

/// What persistence actually buys the user: undo that survives a relaunch, a
/// conversation that resumes, and a remembered answer to a repeated question.
@Suite("Memory behaviour")
struct MemoryBehaviourTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)

    private func makeAssembly(
        calendars: InMemoryCalendarService,
        reminders: InMemoryReminderService,
        memory: any MemoryStore
    ) -> SARACoreAssembly.Result {
        SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: reminders,
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now),
            memory: memory
        )
    }

    @discardableResult
    private func say(_ text: String, to manager: ConversationManager) async -> String {
        let turn = await manager.handle(UserRequest(text: text, source: .text, timestamp: now))
        return turn.messages.map(\.text).joined(separator: "\n")
    }

    // MARK: - Action history

    @Test("History is written through to storage as actions happen")
    func historyIsPersisted() async throws {
        let store = InMemoryMemoryStore()
        let history = ActionHistory(store: store)

        await history.record(
            HistoryEntry(
                timestamp: now,
                summary: "creating Gym",
                reversal: .deleteCreatedEvent(EventIdentifier("e1"))
            )
        )

        #expect(await store.storedHistoryCount == 1)
        #expect(await history.persistenceFailure == nil)
    }

    @Test("Popping an entry removes it from storage, so undo cannot run twice")
    func popRemovesFromStorage() async throws {
        let store = InMemoryMemoryStore()
        let history = ActionHistory(store: store)
        await history.record(
            HistoryEntry(
                timestamp: now,
                summary: "creating Gym",
                reversal: .deleteCreatedEvent(EventIdentifier("e1"))
            )
        )

        let popped = await history.popMostRecent()
        #expect(popped != nil)
        #expect(await store.storedHistoryCount == 0)
        #expect(await history.canUndo == false)
    }

    @Test("Restoring brings back what an earlier session recorded")
    func historyRestores() async throws {
        let store = InMemoryMemoryStore()
        try await store.appendHistory(
            HistoryEntry(
                timestamp: now,
                summary: "creating Gym",
                reversal: .deleteCreatedEvent(EventIdentifier("e1"))
            )
        )

        let history = ActionHistory(store: store)
        #expect(await history.canUndo == false)

        await history.restore()
        #expect(await history.canUndo)
        #expect(await history.mostRecent?.summary == "creating Gym")
    }

    @Test("A storage failure is recorded, not thrown at the action that just succeeded")
    func storageFailureIsSurfacedNotThrown() async throws {
        let store = InMemoryMemoryStore()
        let history = ActionHistory(store: store)
        await store.setFailure(.underlying("disk full"))

        await history.record(
            HistoryEntry(
                timestamp: now,
                summary: "creating Gym",
                reversal: .deleteCreatedEvent(EventIdentifier("e1"))
            )
        )

        // The action still happened, so undo still works this session.
        #expect(await history.canUndo)
        #expect(await history.persistenceFailure != nil)
    }

    // MARK: - Across a relaunch

    @Test("\"Undo that\" still works after the app is restarted")
    func undoSurvivesRelaunch() async throws {
        let calendars = InMemoryCalendarService()
        let reminders = InMemoryReminderService()
        let store = InMemoryMemoryStore()

        // First session: create an event, then the app goes away.
        let first = makeAssembly(calendars: calendars, reminders: reminders, memory: store)
        await first.restore()
        await say("Schedule gym tomorrow at 4 PM", to: first.manager)
        #expect(await calendars.allEvents.count == 1)

        // Second session: a completely new object graph over the same storage.
        let second = makeAssembly(calendars: calendars, reminders: reminders, memory: store)
        await second.restore()

        let reply = await say("Undo that", to: second.manager)
        #expect(reply.contains("undone"))
        #expect(await calendars.allEvents.isEmpty)
    }

    @Test("Without storage, undo does not survive a restart and says so")
    func undoDoesNotSurviveWithoutStorage() async throws {
        let calendars = InMemoryCalendarService()
        let reminders = InMemoryReminderService()

        let first = SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: reminders,
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now)
        )
        await say("Schedule gym tomorrow at 4 PM", to: first.manager)

        let second = SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: reminders,
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now)
        )
        await second.restore()

        let reply = await say("Undo that", to: second.manager)
        #expect(reply == "There's nothing for me to undo.")
        #expect(await calendars.allEvents.count == 1)
    }

    @Test("The recent conversation is stored and restored")
    func sessionIsRestored() async throws {
        let store = InMemoryMemoryStore()
        let first = makeAssembly(
            calendars: InMemoryCalendarService(),
            reminders: InMemoryReminderService(),
            memory: store
        )
        await say("Schedule gym tomorrow at 4 PM", to: first.manager)

        // Both sides of the exchange are kept.
        #expect(await store.storedTurnCount >= 2)

        let restored = try await store.loadTurns(limit: 10)
        #expect(restored.first?.author == .user)
        #expect(restored.contains { $0.author == .sara })
    }

    // MARK: - Remembered choices

    @Test("The calendar chosen for an ambiguous name is offered first next time")
    func rememberedChoiceIsOfferedFirst() async throws {
        let icloud = CalendarDescriptor(
            id: CalendarIdentifier("home-icloud"), title: "Home",
            sourceTitle: "iCloud", allowsModification: true, isDefaultForNewEvents: true
        )
        let gmail = CalendarDescriptor(
            id: CalendarIdentifier("home-gmail"), title: "Home",
            sourceTitle: "Gmail", allowsModification: true, isDefaultForNewEvents: false
        )
        let calendars = InMemoryCalendarService(calendars: [icloud, gmail])
        let store = InMemoryMemoryStore()
        let assembly = makeAssembly(
            calendars: calendars,
            reminders: InMemoryReminderService(),
            memory: store
        )

        // Asked the first time, iCloud listed first because it is the default.
        let firstQuestion = await say("Schedule dinner on my Home calendar tomorrow at 7 PM", to: assembly.manager)
        #expect(firstQuestion.contains("Which calendar do you mean?"))
        #expect(firstQuestion.contains("Home (iCloud)"))

        // The user picks the other one.
        await say("Home (Gmail)", to: assembly.manager)
        #expect(await calendars.allEvents.first?.calendarID == gmail.id)

        // Asked again, the remembered answer leads.
        let secondQuestion = await say("Schedule lunch on my Home calendar tomorrow at 1 PM", to: assembly.manager)
        let gmailPosition = try #require(secondQuestion.range(of: "Home (Gmail)"))
        let icloudPosition = try #require(secondQuestion.range(of: "Home (iCloud)"))
        #expect(gmailPosition.lowerBound < icloudPosition.lowerBound)
    }

    @Test("A remembered choice still has to be confirmed, never applied silently")
    func rememberedChoiceDoesNotAutoSelect() async throws {
        let icloud = CalendarDescriptor(
            id: CalendarIdentifier("home-icloud"), title: "Home",
            sourceTitle: "iCloud", allowsModification: true, isDefaultForNewEvents: true
        )
        let gmail = CalendarDescriptor(
            id: CalendarIdentifier("home-gmail"), title: "Home",
            sourceTitle: "Gmail", allowsModification: true, isDefaultForNewEvents: false
        )
        let calendars = InMemoryCalendarService(calendars: [icloud, gmail])
        let store = InMemoryMemoryStore()
        try await store.remember(
            MemoryRecord(
                kind: .preference,
                subject: MemorySubject.calendarChoice(forName: "home"),
                content: "Home (Gmail)",
                createdAt: now
            )
        )
        let assembly = makeAssembly(
            calendars: calendars,
            reminders: InMemoryReminderService(),
            memory: store
        )

        let question = await say("Schedule dinner on my Home calendar tomorrow at 7 PM", to: assembly.manager)
        #expect(question.contains("Which calendar do you mean?"))
        #expect(await calendars.createCount == 0)
    }

    @Test("Picking one record out of several is not stored as a preference")
    func recordChoicesAreNotRemembered() async throws {
        let calendars = InMemoryCalendarService()
        let store = InMemoryMemoryStore()
        let assembly = makeAssembly(
            calendars: calendars,
            reminders: InMemoryReminderService(),
            memory: store
        )

        await say("Schedule Gym tomorrow at 8 AM", to: assembly.manager)
        await say("Schedule Gym tomorrow at 6 PM", to: assembly.manager)
        await say("Delete Gym tomorrow", to: assembly.manager)
        await say("the second one", to: assembly.manager)

        // A one-off choice about which record is not a lasting preference.
        #expect(await store.storedMemories.isEmpty)
    }
}
