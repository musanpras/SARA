import Foundation

/// The single door between SARA and any language model.
///
/// It asks the router which providers to try, minimises what each one is shown,
/// and returns the first usable result. Its output is always SARA's own types,
/// so nothing downstream knows or cares which model answered.
public struct IntelligenceGateway: Sendable {
    private let router: AIRouter
    private let privacy: PrivacyGateway

    public init(router: AIRouter, privacy: PrivacyGateway = PrivacyGateway()) {
        self.router = router
        self.privacy = privacy
    }

    public func interpret(_ input: AIInput) async throws -> AIResult {
        let candidates = await router.candidates(for: input)
        guard !candidates.isEmpty else {
            throw AIProviderError.unavailable(providerID: "none")
        }

        var lastError: Error?
        for provider in candidates {
            do {
                return try await provider.interpret(privacy.minimize(input, for: provider))
            } catch is CancellationError {
                throw AIProviderError.cancelled
            } catch {
                // A provider that cannot handle this phrasing is not a failure
                // of the request; the next one gets a turn.
                lastError = error
                continue
            }
        }

        throw lastError ?? AIProviderError.unavailable(providerID: "none")
    }
}
