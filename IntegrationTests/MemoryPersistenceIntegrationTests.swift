import Foundation
import SwiftData
import Testing
import SARACore
@testable import SARAKit

/// Persistence against a real on-disk SwiftData store.
///
/// The conformance tests run against an in-memory container, which proves the
/// logic but not that anything actually survives the process losing its
/// `ModelContext`. These open a store, close it, and open a fresh one over the
/// same file.
@Suite("SwiftData persistence", .serialized)
struct MemoryPersistenceIntegrationTests {
    /// A container backed by a throwaway file, so a test never touches the
    /// app's real database.
    private func makeTemporaryContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: SwiftDataMemoryStore.schema,
            configurations: ModelConfiguration(schema: SwiftDataMemoryStore.schema, url: url)
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sara-memory-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: url.deletingPathExtension()
                    .appendingPathExtension("store\(suffix)")
            )
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Preferences survive the store being closed and reopened")
    func preferencesSurvive() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }

        do {
            let store = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
            var preferences = SARAPreferences.default
            preferences.speaksResponses = false
            preferences.temporal.defaultReminderHour = 7
            try await store.savePreferences(preferences)
        }

        // A completely new store over the same file.
        let reopened = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
        let loaded = try await reopened.loadPreferences()

        #expect(loaded?.speaksResponses == false)
        #expect(loaded?.temporal.defaultReminderHour == 7)
    }

    @Test("An undoable action survives a relaunch")
    func historySurvives() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }

        let entry = HistoryEntry(
            timestamp: Date(),
            summary: "creating Gym",
            reversal: .deleteCreatedEvent(EventIdentifier("event-1"))
        )

        do {
            let store = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
            let history = ActionHistory(store: store)
            await history.record(entry)
            #expect(await history.persistenceFailure == nil)
        }

        let reopened = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
        let history = ActionHistory(store: reopened)
        await history.restore()

        #expect(await history.canUndo)
        let restored = try #require(await history.mostRecent)
        #expect(restored.summary == "creating Gym")
        guard case .deleteCreatedEvent(let id) = restored.reversal else {
            Issue.record("Expected a deleteCreatedEvent reversal")
            return
        }
        #expect(id == EventIdentifier("event-1"))
    }

    @Test("Remembered choices and their use counts survive a relaunch")
    func memoriesSurvive() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }

        let subject = MemorySubject.calendarChoice(forName: "home")
        let now = Date()

        do {
            let store = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
            for _ in 0..<2 {
                try await store.remember(
                    MemoryRecord(
                        kind: .preference,
                        subject: subject,
                        content: "Home (iCloud)",
                        createdAt: now
                    )
                )
            }
        }

        let reopened = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
        let recalled = try await reopened.recall(
            MemoryQuery(kinds: [.preference], subject: subject, limit: 5, now: now)
        )

        #expect(recalled.count == 1)
        #expect(recalled.first?.memory.content == "Home (iCloud)")
        #expect(recalled.first?.memory.useCount ?? 0 >= 1)
    }

    @Test("The conversation resumes where it left off")
    func turnsSurvive() async throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }

        let now = Date()
        do {
            let store = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
            try await store.appendTurn(.user("schedule gym tomorrow at 4 pm", at: now))
            try await store.appendTurn(.sara("Done.", kind: .success, at: now.addingTimeInterval(1)))
        }

        let reopened = SwiftDataMemoryStore(modelContainer: try makeTemporaryContainer(at: url))
        let turns = try await reopened.loadTurns(limit: 10)

        #expect(turns.map(\.author) == [.user, .sara])
        #expect(turns.last?.kind == .success)
    }
}
