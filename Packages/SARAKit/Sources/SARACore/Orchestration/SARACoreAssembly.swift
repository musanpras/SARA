import Foundation

/// Builds a wired `ConversationManager` from its collaborators.
///
/// Keeping assembly in one place means tests and the app share the same graph,
/// differing only in which services and providers are injected.
public enum SARACoreAssembly {
    public struct Result: Sendable {
        public let manager: ConversationManager
        public let history: ActionHistory

        /// Loads stored history and the recent conversation. Call once before
        /// the first request, so "undo that" works across a relaunch.
        public func restore() async {
            await history.restore()
            await manager.restoreSession()
        }
    }

    public static func make(
        calendarService: any CalendarService,
        reminderService: any ReminderService,
        providers: [any AIProvider],
        network: any NetworkAvailability = AssumeOffline(),
        dateProvider: any DateProvider = SystemDateProvider(),
        preferences: SARAPreferences = .default,
        memory: (any MemoryStore)? = nil,
        history: ActionHistory? = nil
    ) -> Result {
        let history = history ?? ActionHistory(store: memory)
        let temporal = TemporalEngine(dateProvider: dateProvider, preferences: preferences.temporal)

        let validator = PlanValidator(
            calendarService: calendarService,
            reminderService: reminderService,
            temporal: temporal,
            preferences: preferences,
            memory: memory
        )
        let router = ToolRouter(
            calendarService: calendarService,
            reminderService: reminderService,
            history: history,
            dateProvider: dateProvider
        )
        let gateway = IntelligenceGateway(
            router: AIRouter(providers: providers, network: network)
        )

        let manager = ConversationManager(
            gateway: gateway,
            validator: validator,
            executor: PlanExecutor(router: router),
            history: history,
            responses: ResponseGenerator(dateProvider: dateProvider),
            dateProvider: dateProvider,
            memory: memory
        )
        return Result(manager: manager, history: history)
    }
}
