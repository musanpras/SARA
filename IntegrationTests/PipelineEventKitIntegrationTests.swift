import EventKit
import Foundation
import Testing
import SARACore
@testable import SARAKit

/// The whole pipeline against the real store: a sentence in, a verified
/// EventKit record out.
extension EventKitIntegrationSuite {
    @Suite("Pipeline")
    struct PipelineEventKitIntegrationTests {
        private let calendarService = EventKitIntegrationSupport.calendarService
        private let reminderService = EventKitIntegrationSupport.reminderService

        private struct Harness {
            let manager: ConversationManager
            let bin: IntegrationCleanup
        }

        private func makeHarness(bin: IntegrationCleanup) -> Harness {
            let assembled = SARACoreAssembly.make(
                calendarService: calendarService,
                reminderService: reminderService,
                // Only the deterministic parser: the simulator has no on-device
                // model, and this suite is testing execution, not interpretation.
                providers: [LocalCommandInterpreter()]
            )
            return Harness(manager: assembled.manager, bin: bin)
        }

        @discardableResult
        private func say(_ text: String, to harness: Harness) async -> String {
            let turn = await harness.manager.handle(
                UserRequest(text: text, source: .text, timestamp: Date())
            )
            return turn.messages.map(\.text).joined(separator: "\n")
        }

        /// Events SARA created in the window this suite works in.
        private func events(matching title: String, dayOffset: Int) async throws -> [CalendarEvent] {
            let slot = EventKitIntegrationSupport.slot(dayOffset: dayOffset, hour: 0)
            let window = DateInterval(start: slot.start, duration: 86_400)
            return try await calendarService.events(in: window)
                .filter { $0.title.localizedCaseInsensitiveContains(title) }
        }

        @Test("\"Schedule ... tomorrow at 4 PM\" produces a real EventKit event")
        func scheduleCreatesRealEvent() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                let reply = await say("Schedule SARAITgym tomorrow at 4 PM for one hour", to: harness)
                #expect(reply.hasPrefix("Done."))

                let found = try await events(matching: "SARAITgym", dayOffset: 1)
                #expect(found.count == 1)

                let event = try #require(found.first)
                await bin.track(event.id)

                let hour = EventKitIntegrationSupport.calendar.component(.hour, from: event.start)
                #expect(hour == 16)
                #expect(event.duration == 3600)
            }
        }

        @Test("A search reads back what SARA just created")
        func searchReadsBackRealEvent() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                await say("Schedule SARAITsearch tomorrow at 11 AM", to: harness)
                if let event = try await events(matching: "SARAITsearch", dayOffset: 1).first {
                    await bin.track(event.id)
                }

            let reply = await say("What's on my calendar tomorrow?", to: harness)
            #expect(reply.contains("SARAITsearch"))
            #expect(reply.contains("tomorrow"))
            // The clock format follows the device locale, so the hour is checked on
            // the record rather than in the sentence; phrasing has its own tests
            // against a pinned locale.
            let event = try #require(try await events(matching: "SARAITsearch", dayOffset: 1).first)
            #expect(EventKitIntegrationSupport.calendar.component(.hour, from: event.start) == 11)
            }
        }

        @Test("A move is applied to the real event and keeps its length")
        func moveUpdatesRealEvent() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                await say("Schedule SARAITmove tomorrow at 9 AM for 90 minutes", to: harness)
                if let event = try await events(matching: "SARAITmove", dayOffset: 1).first {
                    await bin.track(event.id)
                }

            await say("Move SARAITmove tomorrow to 2 PM", to: harness)

            let moved = try #require(try await events(matching: "SARAITmove", dayOffset: 1).first)
            let hour = EventKitIntegrationSupport.calendar.component(.hour, from: moved.start)
            #expect(hour == 14)
            #expect(moved.duration == 5400)
            }
        }

        @Test("A confirmed delete removes the event from the real store")
        func deleteRemovesRealEvent() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                await say("Schedule SARAITdelete tomorrow at 3 PM", to: harness)
                let before = try await events(matching: "SARAITdelete", dayOffset: 1)
                #expect(before.count == 1)

                let question = await say("Delete SARAITdelete tomorrow", to: harness)
                #expect(question.contains("Do you want me to delete it?"))

                // Nothing is removed until the user agrees.
                let stillThere = try await events(matching: "SARAITdelete", dayOffset: 1)
                #expect(stillThere.count == 1)

                await say("yes", to: harness)
                let afterConfirmation = try await events(matching: "SARAITdelete", dayOffset: 1)
                #expect(afterConfirmation.isEmpty)
            }
        }

        @Test("Undo reverses a real creation")
        func undoRemovesRealEvent() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                await say("Schedule SARAITundo tomorrow at 5 PM", to: harness)
                let created = try await events(matching: "SARAITundo", dayOffset: 1)
                #expect(created.count == 1)

                let reply = await say("Undo that", to: harness)
                #expect(reply.contains("undone"))
                let afterUndo = try await events(matching: "SARAITundo", dayOffset: 1)
                #expect(afterUndo.isEmpty)
            }
        }

        @Test("A reminder command produces a real reminder")
        func reminderIsCreated() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                let reply = await say("Remind me to SARAITtask tomorrow at 8 PM", to: harness)
                #expect(reply.hasPrefix("Done."))

                let slot = EventKitIntegrationSupport.slot(dayOffset: 1, hour: 0)
                let found = try await reminderService.reminders(
                    dueIn: DateInterval(start: slot.start, duration: 86_400)
                ).filter { $0.title.localizedCaseInsensitiveContains("SARAITtask") }

                #expect(found.count == 1)
                let reminder = try #require(found.first)
                await bin.track(reminder.id)

                let hour = EventKitIntegrationSupport.calendar.component(
                    .hour,
                    from: try #require(reminder.dueDate)
                )
                #expect(hour == 20)
            }
        }

        @Test("A real conflict is detected and asked about before scheduling")
        func conflictIsDetected() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let harness = makeHarness(bin: bin)
                await say("Schedule SARAITfirst tomorrow at 1 PM for one hour", to: harness)

                if let existing = try await events(matching: "SARAITfirst", dayOffset: 1).first {
                    await bin.track(existing.id)
                }

                let question = await say("Schedule SARAITsecond tomorrow at 1 PM", to: harness)
                #expect(question.contains("SARAITfirst"))

                // The overlapping event is not created until the user agrees.
                let notYetCreated = try await events(matching: "SARAITsecond", dayOffset: 1)
                #expect(notYetCreated.isEmpty)

                await say("yes", to: harness)
                let second = try await events(matching: "SARAITsecond", dayOffset: 1)
                #expect(second.count == 1)
                if let created = second.first {
                    await bin.track(created.id)
                }
            }
        }
    }

}
