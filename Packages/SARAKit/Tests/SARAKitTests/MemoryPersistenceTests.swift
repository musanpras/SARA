import Foundation
import Testing
import SARACore
import SARATesting
@testable import SARAKit

/// Behaviour every `MemoryStore` must share, run against both implementations
/// so the SwiftData store and the in-memory one cannot drift apart.
@Suite("Memory stores")
struct MemoryStoreConformanceTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800)

    private static func swiftDataStore() throws -> SwiftDataMemoryStore {
        SwiftDataMemoryStore(modelContainer: try SwiftDataMemoryStore.makeContainer(inMemory: true))
    }

    /// Both implementations, built fresh for each test.
    private static func stores() throws -> [(name: String, store: any MemoryStore)] {
        [
            ("in-memory", InMemoryMemoryStore()),
            ("swiftdata", try swiftDataStore()),
        ]
    }

    @Test("Preferences round-trip")
    func preferencesRoundTrip() async throws {
        for (name, store) in try Self.stores() {
            #expect(try await store.loadPreferences() == nil, "\(name)")

            var preferences = SARAPreferences.default
            preferences.speaksResponses = false
            preferences.preferredCalendarName = "Work"
            preferences.temporal.defaultReminderHour = 7
            try await store.savePreferences(preferences)

            let loaded = try await store.loadPreferences()
            #expect(loaded?.speaksResponses == false, "\(name)")
            #expect(loaded?.preferredCalendarName == "Work", "\(name)")
            #expect(loaded?.temporal.defaultReminderHour == 7, "\(name)")
        }
    }

    @Test("Saving preferences twice updates rather than accumulates")
    func preferencesAreSingular() async throws {
        for (name, store) in try Self.stores() {
            try await store.savePreferences(SARAPreferences(preferredCalendarName: "First"))
            try await store.savePreferences(SARAPreferences(preferredCalendarName: "Second"))

            #expect(try await store.loadPreferences()?.preferredCalendarName == "Second", "\(name)")
        }
    }

    @Test("History round-trips oldest first, newest last")
    func historyOrdering() async throws {
        for (name, store) in try Self.stores() {
            for index in 0..<3 {
                try await store.appendHistory(
                    HistoryEntry(
                        timestamp: now.addingTimeInterval(Double(index)),
                        summary: "action \(index)",
                        reversal: .deleteCreatedEvent(EventIdentifier("e\(index)"))
                    )
                )
            }

            let loaded = try await store.loadHistory(limit: 10)
            #expect(loaded.map(\.summary) == ["action 0", "action 1", "action 2"], "\(name)")
        }
    }

    @Test("A history limit keeps the newest entries")
    func historyLimit() async throws {
        for (name, store) in try Self.stores() {
            for index in 0..<5 {
                try await store.appendHistory(
                    HistoryEntry(
                        timestamp: now.addingTimeInterval(Double(index)),
                        summary: "action \(index)",
                        reversal: .deleteCreatedEvent(EventIdentifier("e\(index)"))
                    )
                )
            }

            let loaded = try await store.loadHistory(limit: 2)
            #expect(loaded.map(\.summary) == ["action 3", "action 4"], "\(name)")
        }
    }

    @Test("A reversal with associated values survives storage")
    func reversalRoundTrip() async throws {
        for (name, store) in try Self.stores() {
            let changes = CalendarEventChanges(
                title: "Gym",
                start: now,
                end: now.addingTimeInterval(3600),
                alerts: [.minutes(30)]
            )
            try await store.appendHistory(
                HistoryEntry(
                    timestamp: now,
                    summary: "changing Gym",
                    reversal: .restoreEvent(id: EventIdentifier("e1"), changes: changes)
                )
            )

            let loaded = try await store.loadHistory(limit: 1).first
            guard case .restoreEvent(let id, let restored)? = loaded?.reversal else {
                Issue.record("Expected a restoreEvent reversal from \(name)")
                return
            }
            #expect(id == EventIdentifier("e1"), "\(name)")
            #expect(restored == changes, "\(name)")
        }
    }

    @Test("Removing a history entry removes exactly that one")
    func historyRemoval() async throws {
        for (name, store) in try Self.stores() {
            let keep = HistoryEntry(
                timestamp: now, summary: "keep",
                reversal: .deleteCreatedEvent(EventIdentifier("keep"))
            )
            let drop = HistoryEntry(
                timestamp: now.addingTimeInterval(1), summary: "drop",
                reversal: .deleteCreatedEvent(EventIdentifier("drop"))
            )
            try await store.appendHistory(keep)
            try await store.appendHistory(drop)

            try await store.removeHistory(id: drop.id)
            #expect(try await store.loadHistory(limit: 10).map(\.summary) == ["keep"], "\(name)")
        }
    }

    @Test("Conversation turns round-trip with author and kind intact")
    func turnsRoundTrip() async throws {
        for (name, store) in try Self.stores() {
            try await store.appendTurn(.user("schedule gym", at: now))
            try await store.appendTurn(
                .sara("Done.", kind: .success, at: now.addingTimeInterval(1))
            )

            let loaded = try await store.loadTurns(limit: 10)
            #expect(loaded.map(\.author) == [.user, .sara], "\(name)")
            #expect(loaded.map(\.text) == ["schedule gym", "Done."], "\(name)")
            #expect(loaded.last?.kind == .success, "\(name)")
        }
    }

    @Test("Repeating a memory reinforces the existing one")
    func memoryReinforcement() async throws {
        for (name, store) in try Self.stores() {
            let subject = MemorySubject.calendarChoice(forName: "home")
            for _ in 0..<3 {
                try await store.remember(
                    MemoryRecord(kind: .preference, subject: subject, content: "Home (iCloud)", createdAt: now)
                )
            }

            let recalled = try await store.recall(
                MemoryQuery(kinds: [.preference], subject: subject, limit: 10, now: now)
            )
            #expect(recalled.count == 1, "\(name)")
            #expect(recalled.first?.memory.useCount ?? 0 >= 2, "\(name)")
        }
    }

    @Test("Recall counts as a use, so recency and usage mean something")
    func recallMarksUse() async throws {
        for (name, store) in try Self.stores() {
            let subject = MemorySubject.calendarChoice(forName: "home")
            try await store.remember(
                MemoryRecord(kind: .preference, subject: subject, content: "Home (iCloud)", createdAt: now)
            )

            let query = MemoryQuery(kinds: [.preference], subject: subject, limit: 1, now: now)
            _ = try await store.recall(query)
            let second = try await store.recall(query)

            #expect(second.first?.memory.useCount ?? 0 >= 1, "\(name)")
        }
    }

    @Test("A forgotten memory is not recalled")
    func forgetting() async throws {
        for (name, store) in try Self.stores() {
            let record = MemoryRecord(kind: .fact, subject: "s", content: "c", createdAt: now)
            try await store.remember(record)

            let recalled = try await store.recall(
                MemoryQuery(kinds: [.fact], subject: "s", limit: 1, now: now)
            )
            try await store.forget(id: try #require(recalled.first).memory.id)

            let after = try await store.recall(
                MemoryQuery(kinds: [.fact], subject: "s", limit: 1, now: now)
            )
            #expect(after.isEmpty, "\(name)")
        }
    }

    @Test("Preferences written by an older build still load, with new defaults")
    func tolerantPreferenceDecoding() throws {
        let legacy = """
        { "openEndedSearchDaysBack": 3, "preferredCalendarName": "Work" }
        """
        let decoded = try JSONDecoder().decode(SARAPreferences.self, from: Data(legacy.utf8))

        #expect(decoded.preferredCalendarName == "Work")
        #expect(decoded.openEndedSearchDaysBack == 3)
        // Absent keys fall back rather than failing the whole decode.
        #expect(decoded.speaksResponses)
        #expect(decoded.temporal.defaultReminderHour == TemporalPreferences.default.defaultReminderHour)
    }
}
