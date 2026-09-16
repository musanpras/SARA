import EventKit
import Foundation
import Testing
import SARACore
@testable import SARAKit

extension EventKitIntegrationSuite {
    @Suite("Reminder service")
    struct ReminderServiceIntegrationTests {
        private let service = EventKitIntegrationSupport.reminderService

        @Test("A created reminder is read back with its due date")
        func createIsVerified() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let due = EventKitIntegrationSupport.slot(dayOffset: 45, hour: 20).start
                let title = EventKitIntegrationSupport.title("reminder")

                let created = try await service.create(
                    ReminderDraft(title: title, dueDate: due, hasTimeComponent: true)
                )
                await bin.track(created.id)

                #expect(created.title == title)
                #expect(created.hasTimeComponent)
                #expect(!created.isCompleted)
                #expect(abs((created.dueDate ?? .distantPast).timeIntervalSince(due)) < 60)

                let fetched = try await service.reminder(id: created.id)
                #expect(fetched?.id == created.id)
            }
        }

        @Test("A date-only reminder is not reported as having a time")
        func dateOnlyReminder() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let due = EventKitIntegrationSupport.slot(dayOffset: 46, hour: 0).start
                let created = try await service.create(
                    ReminderDraft(
                        title: EventKitIntegrationSupport.title("dateonly"),
                        dueDate: due,
                        hasTimeComponent: false
                    )
                )
                await bin.track(created.id)

                #expect(!created.hasTimeComponent)
            }
        }

        @Test("Completing a reminder removes it from the open list")
        func completionIsPersisted() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let due = EventKitIntegrationSupport.slot(dayOffset: 47, hour: 12).start
                let created = try await service.create(
                    ReminderDraft(title: EventKitIntegrationSupport.title("complete"), dueDate: due)
                )
                await bin.track(created.id)

                let completed = try await service.update(
                    id: created.id,
                    changes: ReminderChanges(isCompleted: true)
                )
                #expect(completed.isCompleted)

                let window = DateInterval(start: due.addingTimeInterval(-3600), duration: 7200)
                let open = try await service.reminders(dueIn: window)
                #expect(!open.contains { $0.id == created.id })
            }
        }

        @Test("A deleted reminder is verified gone")
        func deleteIsVerified() async throws {
            let due = EventKitIntegrationSupport.slot(dayOffset: 48, hour: 9).start
            let created = try await service.create(
                ReminderDraft(title: EventKitIntegrationSupport.title("delete"), dueDate: due)
            )

            try await service.delete(id: created.id)

            let fetched = try await service.reminder(id: created.id)
            #expect(fetched == nil)
        }

        @Test("At least one writable list is reported, with a default")
        func listsAreDiscovered() async throws {
            let lists = try await service.lists()
            #expect(!lists.isEmpty)
            let fallback = try await service.defaultList()
            #expect(fallback != nil)
        }
    }

}
