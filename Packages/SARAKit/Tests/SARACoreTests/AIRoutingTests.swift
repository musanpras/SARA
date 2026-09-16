import Foundation
import Testing
@testable import SARACore

private struct StubProvider: AIProvider {
    let identifier: String
    let capabilities: ProviderCapabilities
    let available: Bool
    let result: AIResult?

    init(
        identifier: String,
        isOnDevice: Bool,
        requiresNetwork: Bool = false,
        reasoningStrength: Double = 0.5,
        relativeCost: Double = 0,
        latency: Duration = .milliseconds(10),
        available: Bool = true,
        result: AIResult? = nil
    ) {
        self.identifier = identifier
        self.capabilities = ProviderCapabilities(
            isOnDevice: isOnDevice,
            requiresNetwork: requiresNetwork,
            reasoningStrength: reasoningStrength,
            relativeCost: relativeCost,
            typicalLatency: latency
        )
        self.available = available
        self.result = result
    }

    func isAvailable() async -> Bool { available }

    func interpret(_ input: AIInput) async throws -> AIResult {
        guard let result else { throw AIProviderError.malformedResponse(detail: identifier) }
        return result
    }
}

private struct StubNetwork: NetworkAvailability {
    let online: Bool
    var isOnline: Bool { get async { online } }
}

@Suite("AI routing")
struct AIRoutingTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800)

    private func input(_ text: String) -> AIInput {
        AIInput(
            request: UserRequest(text: text, source: .text, timestamp: now),
            context: InterpretationContext(now: now)
        )
    }

    private var local: StubProvider {
        StubProvider(identifier: "local", isOnDevice: true, reasoningStrength: 0.25, relativeCost: 0)
    }

    private var onDeviceModel: StubProvider {
        StubProvider(identifier: "apple", isOnDevice: true, reasoningStrength: 0.6, relativeCost: 0, latency: .milliseconds(400))
    }

    private var cloud: StubProvider {
        StubProvider(
            identifier: "cloud", isOnDevice: false, requiresNetwork: true,
            reasoningStrength: 0.95, relativeCost: 1, latency: .milliseconds(1200)
        )
    }

    @Test("Routine work prefers the cheapest local path")
    func routinePrefersLocal() async {
        let router = AIRouter(providers: [cloud, onDeviceModel, local], network: StubNetwork(online: true))
        let ordered = await router.candidates(for: input("schedule gym tomorrow at 4 pm"))
        #expect(ordered.map(\.identifier) == ["local", "apple", "cloud"])
    }

    @Test("Complex reasoning prefers the strongest provider")
    func complexPrefersStrongest() async {
        let router = AIRouter(providers: [local, onDeviceModel, cloud], network: StubNetwork(online: true))
        let ordered = await router.candidates(for: input("Find me a two hour gap next week between my meetings"))
        #expect(ordered.first?.identifier == "cloud")
    }

    @Test("Offline drops network providers instead of failing on them")
    func offlineSkipsCloud() async {
        let router = AIRouter(providers: [cloud, onDeviceModel, local], network: StubNetwork(online: false))
        let ordered = await router.candidates(for: input("Find me a two hour gap next week between my meetings"))
        #expect(ordered.map(\.identifier) == ["apple", "local"])
    }

    @Test("Sensitive requests stay on device even when a cloud model is reachable")
    func sensitiveStaysLocal() async {
        let router = AIRouter(providers: [cloud, onDeviceModel, local], network: StubNetwork(online: true))
        let ordered = await router.candidates(
            for: input("Find me a time next week for my therapy appointment and rearrange the rest")
        )
        let allLocal = ordered.allSatisfy { $0.capabilities.isOnDevice }
        #expect(allLocal)
    }

    @Test("An unavailable provider is never offered")
    func unavailableSkipped() async {
        let broken = StubProvider(identifier: "apple", isOnDevice: true, available: false)
        let router = AIRouter(providers: [broken, local], network: StubNetwork(online: true))
        let ordered = await router.candidates(for: input("schedule gym tomorrow at 4 pm"))
        #expect(ordered.map(\.identifier) == ["local"])
    }

    @Test("The gateway falls through to the next provider when one cannot answer")
    func gatewayFallsThrough() async throws {
        let failing = StubProvider(identifier: "local", isOnDevice: true, relativeCost: 0, result: nil)
        let working = StubProvider(
            identifier: "apple", isOnDevice: true, relativeCost: 0.1,
            result: .conversation("Hello")
        )
        let gateway = IntelligenceGateway(
            router: AIRouter(providers: [failing, working], network: StubNetwork(online: false))
        )

        let result = try await gateway.interpret(input("hello there"))
        guard case .conversation(let text) = result else {
            Issue.record("Expected a conversational reply")
            return
        }
        #expect(text == "Hello")
    }

    @Test("No usable provider is reported rather than silently ignored")
    func noProvidersReported() async throws {
        let gateway = IntelligenceGateway(
            router: AIRouter(providers: [cloud], network: StubNetwork(online: false))
        )
        await #expect(throws: AIProviderError.unavailable(providerID: "none")) {
            _ = try await gateway.interpret(input("schedule gym"))
        }
    }

    @Test("Off-device providers see redacted, trimmed context")
    func privacyMinimization() {
        let gateway = PrivacyGateway(offDeviceTurnLimit: 2)
        let turns = (0..<5).map { ConversationMessage.user("turn \($0)", at: now) }
        let context = InterpretationContext(
            recentTurns: turns,
            references: ReferenceContext(
                presentedEvents: [
                    CalendarEvent(
                        id: EventIdentifier("e1"), title: "Therapy", start: now, end: now,
                        calendarID: CalendarIdentifier("c"), calendarTitle: "Personal"
                    )
                ]
            ),
            now: now
        )
        let request = UserRequest(
            text: "Email sam@example.com about tomorrow, call +1 555 123 4567",
            source: .text,
            timestamp: now
        )

        let minimized = gateway.minimize(AIInput(request: request, context: context), for: cloud)

        #expect(minimized.context.recentTurns.count == 2)
        #expect(minimized.context.references.presentedEvents.isEmpty)
        #expect(minimized.request.text.contains("[email]"))
        #expect(minimized.request.text.contains("[phone]"))
        #expect(!minimized.request.text.contains("sam@example.com"))
    }

    @Test("On-device providers see the context untouched")
    func onDeviceContextIsIntact() {
        let gateway = PrivacyGateway()
        let request = UserRequest(text: "Email sam@example.com", source: .text, timestamp: now)
        let input = AIInput(request: request, context: InterpretationContext(now: now))

        let minimized = gateway.minimize(input, for: local)
        #expect(minimized.request.text == "Email sam@example.com")
    }
}
