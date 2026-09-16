import EventKit
import Foundation
import SARACore

/// The application's composition root.
///
/// One place decides which concrete services, providers and storage SARA runs
/// with. Everything below it depends on protocols, so tests swap the EventKit
/// services and the memory store for in-memory ones and change nothing else.
@MainActor
public final class AppEnvironment {
    public let conversation: ConversationManager
    public let history: ActionHistory
    public let calendarService: EventKitCalendarService
    public let reminderService: EventKitReminderService
    public let memory: any MemoryStore
    public let speech: SpeechManager
    public let voice: any VoiceOutputProvider
    /// Wake-word engine for hands-free interaction while the app is open.
    public let wakeWord: any WakeWordDetecting
    /// Central voice tuning (wake phrase, silence window, limits).
    public let voiceConfiguration: VoiceConfiguration
    /// Preferences as loaded at start-up.
    public let preferences: SARAPreferences
    /// Set when storage could not be opened on disk, so the UI can tell the
    /// user that SARA will forget things when it closes.
    public let storageWarning: String?

    /// Builds the environment, loading stored preferences and memory first.
    ///
    /// Asynchronous because preferences decide how the temporal engine and
    /// validator behave, so they have to be read before the graph is wired
    /// rather than patched in afterwards.
    public static func bootstrap() async -> AppEnvironment {
        let (store, warning) = await makeStore()
        let preferences = (try? await store.preferencesOrDefault()) ?? .default
        return AppEnvironment(memory: store, preferences: preferences, storageWarning: warning)
    }

    private init(
        memory: any MemoryStore,
        preferences: SARAPreferences,
        storageWarning: String?
    ) {
        // Each service owns its own EKEventStore. The store is not thread-safe,
        // so sharing one between two actors would be a data race; authorization
        // is granted per app rather than per store, so nothing is lost by
        // keeping them separate.
        let dateProvider = SystemDateProvider()

        let calendarService = EventKitCalendarService(store: EKEventStore())
        let reminderService = EventKitReminderService(
            store: EKEventStore(),
            calendar: dateProvider.calendar
        )
        self.calendarService = calendarService
        self.reminderService = reminderService
        self.memory = memory
        self.preferences = preferences
        self.storageWarning = storageWarning

        let assembled = SARACoreAssembly.make(
            calendarService: calendarService,
            reminderService: reminderService,
            // Order is a preference, not a fallback chain: the router decides
            // per request. The deterministic parser handles regular phrasing
            // for free; the on-device model covers the rest.
            providers: [LocalCommandInterpreter(), AppleFoundationModelProvider()],
            network: NetworkMonitor(),
            dateProvider: dateProvider,
            preferences: preferences,
            memory: memory
        )
        self.conversation = assembled.manager
        self.history = assembled.history

        let voiceConfiguration = VoiceConfiguration.default
        self.voiceConfiguration = voiceConfiguration
        self.speech = SpeechManager()
        self.voice = SystemVoiceOutputProvider()
        self.wakeWord = SpeechWakeWordDetector(phrase: voiceConfiguration.wakeWord)

        self.assembled = assembled
    }

    private let assembled: SARACoreAssembly.Result

    /// Loads stored history and the recent conversation.
    public func restore() async {
        await assembled.restore()
    }

    /// Opens on-disk storage, degrading to a memory-only store if it cannot.
    ///
    /// The same SwiftData implementation is used either way, so behaviour is
    /// identical apart from persistence — and the caller is told which it got
    /// rather than discovering it when nothing is remembered.
    private static func makeStore() async -> (any MemoryStore, String?) {
        do {
            let container = try SwiftDataMemoryStore.makeContainer()
            return (SwiftDataMemoryStore(modelContainer: container), nil)
        } catch {
            do {
                let container = try SwiftDataMemoryStore.makeContainer(inMemory: true)
                return (
                    SwiftDataMemoryStore(modelContainer: container),
                    "I couldn't open my local storage, so I'll forget this session when you close me."
                )
            } catch {
                // Nothing usable at all. The pipeline runs without memory.
                return (NoMemoryStore(), "I can't store anything locally right now.")
            }
        }
    }
}

/// Last-resort store that keeps nothing.
///
/// Used only when SwiftData cannot open even an in-memory container. SARA
/// still answers and still acts on the calendar; it just cannot remember.
struct NoMemoryStore: MemoryStore {
    func loadPreferences() async throws -> SARAPreferences? { nil }
    func savePreferences(_ preferences: SARAPreferences) async throws {}
    func appendHistory(_ entry: HistoryEntry) async throws {}
    func loadHistory(limit: Int) async throws -> [HistoryEntry] { [] }
    func removeHistory(id: UUID) async throws {}
    func clearHistory() async throws {}
    func appendTurn(_ message: ConversationMessage) async throws {}
    func loadTurns(limit: Int) async throws -> [ConversationMessage] { [] }
    func clearTurns() async throws {}
    func remember(_ memory: MemoryRecord) async throws {}
    func recall(_ query: MemoryQuery) async throws -> [ScoredMemory] { [] }
    func forget(id: UUID) async throws {}
    func clearMemories() async throws {}
}
