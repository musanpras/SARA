import Foundation
import Testing
import SARACore
@testable import SARAKit

/// The reported flow, end to end in the app process: ask to delete something
/// real, say no, and keep using SARA.
extension EventKitIntegrationSuite {
    @MainActor
    @Suite("Declining")
    struct DeclineFlowIntegrationTests {
        private func makeViewModel(bin: IntegrationCleanup) -> ConversationViewModel {
            let assembled = SARACoreAssembly.make(
                calendarService: EventKitIntegrationSupport.calendarService,
                reminderService: EventKitIntegrationSupport.reminderService,
                providers: [LocalCommandInterpreter()]
            )
            return ConversationViewModel(handler: assembled.manager)
        }

        private func reply(_ viewModel: ConversationViewModel) -> String {
            viewModel.transcript.lastSaraMessage?.text ?? ""
        }

        @Test("Saying no to deleting an event leaves it alone and leaves SARA usable")
        func decliningEventDeletion() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let viewModel = makeViewModel(bin: bin)

                await viewModel.submit(
                    text: "Schedule SARAITdecline tomorrow at 3 PM",
                    source: .text,
                    confidence: nil
                )
                let slot = EventKitIntegrationSupport.slot(dayOffset: 1, hour: 0)
                let window = DateInterval(start: slot.start, duration: 86_400)

                let created = try await EventKitIntegrationSupport.calendarService
                    .events(in: window)
                    .filter { $0.title.contains("SARAITdecline") }
                #expect(created.count == 1)
                if let event = created.first { await bin.track(event.id) }

                await viewModel.submit(text: "Delete SARAITdecline tomorrow", source: .text, confidence: nil)
                guard case .confirming = viewModel.state else {
                    Issue.record("Expected a confirmation, got \(viewModel.state)")
                    return
                }

                // The reported crash happened here.
                await viewModel.submit(text: "no", source: .text, confidence: nil)

                #expect(viewModel.state == .idle)
                #expect(viewModel.canSubmit)
                #expect(reply(viewModel) == "Alright, I've left it as it is.")

                let stillThere = try await EventKitIntegrationSupport.calendarService
                    .events(in: window)
                    .filter { $0.title.contains("SARAITdecline") }
                #expect(stillThere.count == 1)

                // SARA must still work afterwards rather than being stuck.
                await viewModel.submit(text: "What's on my calendar tomorrow?", source: .text, confidence: nil)
                #expect(reply(viewModel).contains("SARAITdecline"))
                #expect(viewModel.canSubmit)
            }
        }

        @Test("Saying no to deleting a reminder behaves the same way")
        func decliningReminderDeletion() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let viewModel = makeViewModel(bin: bin)

                await viewModel.submit(
                    text: "Remind me to SARAITkeep tomorrow at 9 AM",
                    source: .text,
                    confidence: nil
                )
                let slot = EventKitIntegrationSupport.slot(dayOffset: 1, hour: 0)
                let window = DateInterval(start: slot.start, duration: 86_400)

                let created = try await EventKitIntegrationSupport.reminderService
                    .reminders(dueIn: window)
                    .filter { $0.title.contains("SARAITkeep") }
                #expect(created.count == 1)
                if let reminder = created.first { await bin.track(reminder.id) }

                await viewModel.submit(
                    text: "Delete the reminder to SARAITkeep",
                    source: .text,
                    confidence: nil
                )
                guard case .confirming = viewModel.state else {
                    Issue.record("Expected a confirmation, got \(viewModel.state)")
                    return
                }

                await viewModel.submit(text: "no", source: .text, confidence: nil)

                #expect(viewModel.state == .idle)
                #expect(viewModel.canSubmit)

                let stillThere = try await EventKitIntegrationSupport.reminderService
                    .reminders(dueIn: window)
                    .filter { $0.title.contains("SARAITkeep") }
                #expect(stillThere.count == 1)
            }
        }

        @Test("A real write passes through executing, naming what it is doing")
        func executingIsShownForRealWork() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let viewModel = makeViewModel(bin: bin)

                var seen: [AssistantState] = []
                let sampler = Task { @MainActor in
                    while !Task.isCancelled {
                        if seen.last != viewModel.state { seen.append(viewModel.state) }
                        await Task.yield()
                    }
                }

                await viewModel.submit(
                    text: "Schedule SARAITprogress tomorrow at 2 PM",
                    source: .text,
                    confidence: nil
                )
                sampler.cancel()

                #expect(seen.contains(.executing(description: "Creating SARAITprogress")))
                #expect(seen.contains(.processing))

                let slot = EventKitIntegrationSupport.slot(dayOffset: 1, hour: 0)
                let created = try await EventKitIntegrationSupport.calendarService
                    .events(in: DateInterval(start: slot.start, duration: 86_400))
                    .filter { $0.title.contains("SARAITprogress") }
                #expect(created.count == 1)
                if let event = created.first { await bin.track(event.id) }
            }
        }

        @Test("Saying yes still deletes, so the fix did not disable confirmation")
        func confirmingStillDeletes() async throws {
            try await EventKitIntegrationSupport.withCleanStore { bin in
                let viewModel = makeViewModel(bin: bin)

                await viewModel.submit(
                    text: "Schedule SARAITgone tomorrow at 4 PM",
                    source: .text,
                    confidence: nil
                )
                await viewModel.submit(text: "Delete SARAITgone tomorrow", source: .text, confidence: nil)
                await viewModel.submit(text: "yes", source: .text, confidence: nil)

                let slot = EventKitIntegrationSupport.slot(dayOffset: 1, hour: 0)
                let remaining = try await EventKitIntegrationSupport.calendarService
                    .events(in: DateInterval(start: slot.start, duration: 86_400))
                    .filter { $0.title.contains("SARAITgone") }
                #expect(remaining.isEmpty)
            }
        }
    }

}
