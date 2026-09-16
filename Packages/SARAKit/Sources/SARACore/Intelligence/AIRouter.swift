import Foundation

/// Whether the device currently has a usable network path.
public protocol NetworkAvailability: Sendable {
    var isOnline: Bool { get async }
}

/// Always-offline stand-in, and the safe default when no monitor is supplied.
public struct AssumeOffline: NetworkAvailability {
    public init() {}
    public var isOnline: Bool { get async { false } }
}

/// Chooses which providers to try, in order, using plain deterministic rules.
///
/// The ordering is auditable and testable: given the same inputs it always
/// picks the same path, and privacy-sensitive work never leaves the device
/// regardless of what a cloud provider could do better.
public struct AIRouter: Sendable {
    private let providers: [any AIProvider]
    private let network: any NetworkAvailability
    private let classifier: TaskClassifier

    public init(
        providers: [any AIProvider],
        network: any NetworkAvailability = AssumeOffline(),
        classifier: TaskClassifier = TaskClassifier()
    ) {
        self.providers = providers
        self.network = network
        self.classifier = classifier
    }

    /// The providers to attempt, best first. An empty result means SARA has no
    /// usable path and must say so rather than fail obscurely.
    public func candidates(for input: AIInput) async -> [any AIProvider] {
        let profile = classifier.profile(for: input.request, context: input.context)
        let online = await network.isOnline

        var eligible: [any AIProvider] = []
        for provider in providers {
            let capabilities = provider.capabilities
            // A cloud provider is skipped outright when offline, rather than
            // tried and reported as a failure.
            if capabilities.requiresNetwork && !online { continue }
            // Sensitive requests stay on device even when a stronger cloud
            // model is available and reachable.
            if profile.sensitivity == .elevated && !capabilities.isOnDevice { continue }
            guard await provider.isAvailable() else { continue }
            eligible.append(provider)
        }

        return eligible.sorted { lhs, rhs in
            order(lhs, before: rhs, complexity: profile.complexity)
        }
    }

    /// Routine work prefers the cheapest local path; complex work prefers the
    /// strongest reasoner, with on-device winning ties.
    private func order(_ lhs: any AIProvider, before rhs: any AIProvider, complexity: TaskComplexity) -> Bool {
        let left = lhs.capabilities
        let right = rhs.capabilities

        if complexity == .complex {
            if left.reasoningStrength != right.reasoningStrength {
                return left.reasoningStrength > right.reasoningStrength
            }
        }

        if left.isOnDevice != right.isOnDevice { return left.isOnDevice }
        if left.relativeCost != right.relativeCost { return left.relativeCost < right.relativeCost }
        if left.typicalLatency != right.typicalLatency { return left.typicalLatency < right.typicalLatency }
        return left.reasoningStrength > right.reasoningStrength
    }
}
