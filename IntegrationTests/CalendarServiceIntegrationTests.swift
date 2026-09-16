import EventKit
import Foundation
import Testing
import SARACore
@testable import SARAKit

extension EventKitIntegrationSuite {
    @Suite("Calendar service")
    struct CalendarServiceIntegrationTests {
        private let service = EventKitIntegrationSupport.calendarService

        @Test("A created event is read back from the store, not assumed")
        func createIsVerified() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let slot = EventKitIntegrationSupport.slot(dayOffset: 40, hour: 9)
                let title = EventKitIntegrationSupport.title("create")

                let created = try await service.create(
                    CalendarEventDraft(title: title, start: slot.start, end: slot.end, alerts: [.minutes(30)])
                )
                await bin.track(created.id)

                #expect(created.title == title)
                #expect(abs(created.start.timeIntervalSince(slot.start)) < 1)
                #expect(created.alerts == [.minutes(30)])
                #expect(!created.calendarTitle.isEmpty)

                // The identifier the service handed back must resolve independently.
                let fetched = try await service.event(id: created.id)
                #expect(fetched?.id == created.id)
                #expect(fetched?.title == title)
            }
        }

        @Test("A created event appears in a date-range search")
        func searchFindsCreatedEvent() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let slot = EventKitIntegrationSupport.slot(dayOffset: 41, hour: 14)
                let title = EventKitIntegrationSupport.title("search")
                let created = try await service.create(
                    CalendarEventDraft(title: title, start: slot.start, end: slot.end)
                )
                await bin.track(created.id)

                let window = DateInterval(start: slot.start.addingTimeInterval(-3600), duration: 7200)
                let found = try await service.events(in: window)
                #expect(found.contains { $0.id == created.id })

                // A window that does not include it must not return it.
                let elsewhere = DateInterval(start: slot.start.addingTimeInterval(86_400), duration: 3600)
                let notFound = try await service.events(in: elsewhere)
                #expect(!notFound.contains { $0.id == created.id })
            }
        }

        @Test("An update is persisted and read back")
        func updateIsPersisted() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let slot = EventKitIntegrationSupport.slot(dayOffset: 42, hour: 10)
                let created = try await service.create(
                    CalendarEventDraft(
                        title: EventKitIntegrationSupport.title("update"),
                        start: slot.start,
                        end: slot.end
                    )
                )
                await bin.track(created.id)

                let movedStart = slot.start.addingTimeInterval(7200)
                let updated = try await service.update(
                    id: created.id,
                    changes: CalendarEventChanges(
                        title: "SARA-IT renamed",
                        start: movedStart,
                        end: movedStart.addingTimeInterval(3600)
                    ),
                    span: .thisEvent
                )

                #expect(updated.title == "SARA-IT renamed")
                #expect(abs(updated.start.timeIntervalSince(movedStart)) < 1)

                let refetched = try await service.event(id: updated.id)
                #expect(refetched?.title == "SARA-IT renamed")
            }
        }

        @Test("A deleted event is verified gone")
        func deleteIsVerified() async throws {
            let slot = EventKitIntegrationSupport.slot(dayOffset: 43, hour: 11)
            let created = try await service.create(
                CalendarEventDraft(
                    title: EventKitIntegrationSupport.title("delete"),
                    start: slot.start,
                    end: slot.end
                )
            )

            try await service.delete(id: created.id, span: .thisEvent)

            let fetched = try await service.event(id: created.id)
            #expect(fetched == nil)
        }

        @Test("Deleting something already gone reports not-found instead of succeeding")
        func deleteMissingReportsNotFound() async throws {
            await #expect(throws: CalendarServiceError.self) {
                try await service.delete(id: EventIdentifier("definitely-not-a-real-identifier"))
            }
        }

        @Test("A recurring event is created as a series")
        func recurrenceIsApplied() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let slot = EventKitIntegrationSupport.slot(dayOffset: 44, hour: 8)
                let created = try await service.create(
                    CalendarEventDraft(
                        title: EventKitIntegrationSupport.title("weekly"),
                        start: slot.start,
                        end: slot.end,
                        recurrence: .everyNWeeks(2, on: [.monday])
                    )
                )
                await bin.track(created.id)

                #expect(created.isRecurring)
            }
        }

        @Test("At least one writable calendar is reported, with a default")
        func calendarsAreDiscovered() async throws {
            let calendars = try await service.calendars()
            #expect(!calendars.isEmpty)
            #expect(calendars.contains { $0.allowsModification })

            let fallback = try await service.defaultCalendar()
            #expect(fallback != nil)
        }
    }

}
