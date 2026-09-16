import Foundation
import Testing
import SARACore
import SARATesting

/// Spoken cancellation, exercised through the real pipeline. "Cancel" / "never
/// mind" must abandon whatever question SARA is holding and touch nothing —
/// distinct from end-of-speech, which is handled by voice-activity detection.
@Suite("Voice cancellation")
struct VoiceCancellationTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)

    private struct Harness {
        let manager: ConversationManager
        let calendars: InMemoryCalendarService
    }

    private func makeHarness() -> Harness {
        let calendars = InMemoryCalendarService(status: .authorized)
        let result = SARACoreAssembly.make(
            calendarService: calendars,
            reminderService: InMemoryReminderService(),
            providers: [LocalCommandInterpreter()],
            dateProvider: FixedDateProvider(now: now)
        )
        return Harness(manager: result.manager, calendars: calendars)
    }

    @discardableResult
    private func say(_ text: String, to harness: Harness) async -> AssistantTurn {
        await harness.manager.handle(UserRequest(text: text, source: .voice, timestamp: now))
    }

    @Test("\"Never mind\" abandons a pending confirmation without deleting")
    func cancelDuringConfirmation() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)

        let question = await say("Delete gym tomorrow", to: harness)
        guard case .confirming = question.state else {
            Issue.record("Expected a confirmation, got \(question.state)")
            return
        }

        let cancelled = await say("never mind", to: harness)
        #expect(cancelled.state == .idle)
        #expect(await harness.calendars.allEvents.count == 1)
        #expect(await harness.calendars.deleteCount == 0)
    }

    @Test("\"Cancel\" abandons a pending clarification and returns to rest")
    func cancelDuringClarification() async throws {
        let harness = makeHarness()
        await say("Schedule Team Meeting today at 2 PM", to: harness)
        await say("Schedule Team Meeting tomorrow at 10 AM", to: harness)

        let question = await say("Delete my Team Meeting", to: harness)
        guard case .clarifying = question.state else {
            Issue.record("Expected a clarification, got \(question.state)")
            return
        }

        let cancelled = await say("cancel", to: harness)
        #expect(cancelled.state == .idle)
        #expect(await harness.calendars.allEvents.count == 2)
    }

    @Test("After cancelling, a fresh command is handled normally")
    func recoversAfterCancel() async throws {
        let harness = makeHarness()
        await say("Schedule gym tomorrow at 4 PM", to: harness)
        await say("Delete gym tomorrow", to: harness)
        await say("never mind", to: harness)

        let next = await say("Schedule lunch tomorrow at noon", to: harness)
        if case .success = next.state {} else {
            Issue.record("Expected success, got \(next.state)")
        }
        #expect(await harness.calendars.allEvents.count == 2)
    }
}
