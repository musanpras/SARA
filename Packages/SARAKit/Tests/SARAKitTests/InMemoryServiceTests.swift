import Foundation
import Testing
import SARACore
import SARATesting

/// Guards the test doubles themselves: if they drift from the contract every
/// downstream pipeline test becomes meaningless.
@Suite("In-memory services")
struct InMemoryServiceTests {
    private let base = Date(timeIntervalSince1970: 1_758_000_000)

    @Test("A created event is readable back with a real identifier")
    func createThenRead() async throws {
        let service = InMemoryCalendarService()
        let created = try await service.create(
            CalendarEventDraft(title: "Gym", start: base, end: base.addingTimeInterval(3600))
        )

        let readBack = try await service.event(id: created.id)
        #expect(readBack == created)
        #expect(created.calendarTitle == "Personal")
    }

    @Test("Creation falls back to the default calendar rather than picking at random")
    func defaultCalendarFallback() async throws {
        let service = InMemoryCalendarService(calendars: [.holidays, .work, .personal])
        let created = try await service.create(
            CalendarEventDraft(title: "Gym", start: base, end: base.addingTimeInterval(3600))
        )
        #expect(created.calendarID == CalendarDescriptor.personal.id)
    }

    @Test("Writing to a read-only calendar is refused")
    func readOnlyCalendarRefused() async {
        let service = InMemoryCalendarService(calendars: [.holidays])
        await #expect(throws: CalendarServiceError.calendarIsReadOnly(CalendarDescriptor.holidays.id)) {
            try await service.create(
                CalendarEventDraft(
                    title: "Gym",
                    start: base,
                    end: base.addingTimeInterval(3600),
                    calendarID: CalendarDescriptor.holidays.id
                )
            )
        }
    }

    @Test("Denied access fails before any write happens")
    func deniedAccessBlocksWrites() async throws {
        let service = InMemoryCalendarService(status: .denied)
        await #expect(throws: CalendarServiceError.self) {
            try await service.create(
                CalendarEventDraft(title: "Gym", start: base, end: base.addingTimeInterval(3600))
            )
        }
        #expect(await service.createCount == 0)
    }

    @Test("Search returns only events overlapping the window")
    func searchWindow() async throws {
        let service = InMemoryCalendarService()
        _ = try await service.create(
            CalendarEventDraft(title: "Today", start: base, end: base.addingTimeInterval(3600))
        )
        _ = try await service.create(
            CalendarEventDraft(
                title: "Next week",
                start: base.addingTimeInterval(7 * 86_400),
                end: base.addingTimeInterval(7 * 86_400 + 3600)
            )
        )

        let window = DateInterval(start: base.addingTimeInterval(-3600), duration: 7200)
        let found = try await service.events(in: window)
        #expect(found.map(\.title) == ["Today"])
    }

    @Test("Deleting an unknown event reports not-found instead of succeeding quietly")
    func deleteUnknown() async {
        let service = InMemoryCalendarService()
        await #expect(throws: CalendarServiceError.eventNotFound(EventIdentifier("nope"))) {
            try await service.delete(id: EventIdentifier("nope"))
        }
    }

    @Test("A reminder with no stated time is not reported as timed")
    func untimedReminder() async throws {
        let service = InMemoryReminderService()
        let created = try await service.create(
            ReminderDraft(title: "Submit assignment", dueDate: base, hasTimeComponent: false)
        )
        #expect(!created.hasTimeComponent)
        #expect(created.listTitle == "Reminders")
    }

    @Test("Clearing a due date is distinct from leaving it unchanged")
    func clearDueDate() async throws {
        let service = InMemoryReminderService()
        let created = try await service.create(ReminderDraft(title: "Call John", dueDate: base))

        let untouched = try await service.update(id: created.id, changes: ReminderChanges(title: "Call Jon"))
        #expect(untouched.dueDate == base)

        let cleared = try await service.update(id: created.id, changes: ReminderChanges(clearDueDate: true))
        #expect(cleared.dueDate == nil)
        #expect(!cleared.hasTimeComponent)
    }

    @Test("Completed reminders are excluded from the default search")
    func completedExcluded() async throws {
        let service = InMemoryReminderService()
        let created = try await service.create(ReminderDraft(title: "Done thing", dueDate: base))
        _ = try await service.update(id: created.id, changes: ReminderChanges(isCompleted: true))

        let open = try await service.reminders(dueIn: nil)
        #expect(open.isEmpty)

        let all = try await service.reminders(dueIn: nil, listIDs: nil, filter: .completedOnly)
        #expect(all.map(\.title) == ["Done thing"])
    }

    @Test("An injected failure is not reported as success")
    func injectedFailure() async throws {
        let service = InMemoryCalendarService()
        await service.setFailure(.underlying("store is busy"))

        await #expect(throws: CalendarServiceError.underlying("store is busy")) {
            try await service.create(
                CalendarEventDraft(title: "Gym", start: base, end: base.addingTimeInterval(3600))
            )
        }
        #expect(await service.allEvents.isEmpty)
    }
}
