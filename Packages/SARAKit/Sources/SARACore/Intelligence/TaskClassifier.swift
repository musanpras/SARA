import Foundation

/// How much reasoning a request plausibly needs.
public enum TaskComplexity: Int, Hashable, Sendable, Comparable {
    /// Regular phrasing the deterministic parser handles.
    case routine
    /// Natural but irregular phrasing that needs a language model.
    case moderate
    /// Open-ended planning or multi-constraint reasoning.
    case complex

    public static func < (lhs: TaskComplexity, rhs: TaskComplexity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How sensitive the request looks, used to keep some work on device.
public enum PrivacySensitivity: Int, Hashable, Sendable, Comparable {
    case normal
    case elevated

    public static func < (lhs: PrivacySensitivity, rhs: PrivacySensitivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TaskProfile: Hashable, Sendable {
    public let complexity: TaskComplexity
    public let sensitivity: PrivacySensitivity

    public init(complexity: TaskComplexity, sensitivity: PrivacySensitivity) {
        self.complexity = complexity
        self.sensitivity = sensitivity
    }
}

/// Classifies a request without calling a model.
///
/// Using an LLM to decide which LLM to use would cost a round trip to answer a
/// question that plain rules answer well enough, so this is deliberately
/// ordinary Swift.
public struct TaskClassifier: Sendable {
    public init() {}

    public func profile(for request: UserRequest, context: InterpretationContext) -> TaskProfile {
        TaskProfile(
            complexity: complexity(for: request, context: context),
            sensitivity: sensitivity(for: request)
        )
    }

    private func complexity(for request: UserRequest, context: InterpretationContext) -> TaskComplexity {
        let text = request.normalizedText.lowercased()

        // Phrases that ask SARA to work something out rather than carry it out.
        let planningMarkers = [
            "find time", "find a time", "find me a", "when am i free", "free time",
            "gap", "reschedule everything", "best time", "work out", "figure out",
            "rearrange", "optimi", "plan my", "fit in",
        ]
        if planningMarkers.contains(where: text.contains) { return .complex }

        // Several clauses usually means several actions with relationships.
        let clauses = text.components(separatedBy: [",", ";"]).count
            + text.components(separatedBy: " and ").count - 1
        if clauses >= 3 { return .complex }

        if request.normalizedText.count > 140 { return .moderate }
        if context.pendingClarification != nil { return .moderate }
        return .routine
    }

    private func sensitivity(for request: UserRequest) -> PrivacySensitivity {
        let text = request.normalizedText.lowercased()
        let sensitiveMarkers = [
            "doctor", "therapy", "therapist", "clinic", "hospital", "surgery",
            "medication", "lawyer", "solicitor", "court", "interview", "divorce",
            "funeral", "counsell", "counsel", "diagnosis", "treatment",
        ]
        return sensitiveMarkers.contains(where: text.contains) ? .elevated : .normal
    }
}
