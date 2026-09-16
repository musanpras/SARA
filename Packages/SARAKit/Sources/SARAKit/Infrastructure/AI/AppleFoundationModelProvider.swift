import Foundation
import SARACore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Interprets natural language with Apple's on-device foundation model.
///
/// It is the escalation path from `LocalCommandInterpreter`: phrasing that is
/// natural but irregular. The model only ever classifies intent and quotes the
/// user's own words back as slots — it never produces a date, an identifier or
/// an EventKit call. Swift converts those slots into a validated `ActionPlan`.
public struct AppleFoundationModelProvider: AIProvider {
    private let instructions = """
    You extract structured commands for a calendar and reminders assistant.
    Read the user's message and fill in the fields.

    Rules:
    - Copy dates and times as the user phrased them. Never calculate a date, \
    never convert to a calendar date, and never invent one that was not said.
    - Leave a field empty when the user did not say it. Do not guess a title, \
    a date or a time.
    - Only use smallTalk for greetings and chat with nothing to schedule.
    - Use somethingElse when the request is about anything other than calendar \
    events and reminders.
    """

    public init() {}

    public let identifier = "apple.foundation"

    public let capabilities = ProviderCapabilities(
        isOnDevice: true,
        requiresNetwork: false,
        reasoningStrength: 0.6,
        relativeCost: 0,
        typicalLatency: .milliseconds(600)
    )

    public func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Why the model cannot be used, phrased for the user. `nil` when it can.
    public func unavailabilityReason() async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support on-device intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence isn't turned on in Settings."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading."
            case .unavailable:
                return "The on-device model isn't available right now."
            }
        }
        #endif
        return "This version of iOS doesn't include the on-device model."
    }

    public func interpret(_ input: AIInput) async throws -> AIResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                throw AIProviderError.unavailable(providerID: identifier)
            }

            let session = LanguageModelSession(instructions: instructions)
            let extracted: ExtractedCommand
            do {
                let response = try await session.respond(
                    to: prompt(for: input),
                    generating: ExtractedCommand.self
                )
                extracted = response.content
            } catch is CancellationError {
                throw AIProviderError.cancelled
            } catch {
                throw AIProviderError.underlying(error.localizedDescription)
            }

            guard let result = ExtractedCommandTranslator().translate(extracted, for: input.request) else {
                throw AIProviderError.malformedResponse(detail: "the model's answer had no usable action")
            }
            return result
        }
        #endif
        throw AIProviderError.unavailable(providerID: identifier)
    }

    /// Includes only the recent turns, because references like "it" are
    /// resolved against real records in Swift, not by the model.
    private func prompt(for input: AIInput) -> String {
        var lines: [String] = []
        if !input.context.recentTurns.isEmpty {
            lines.append("Recent conversation:")
            for message in input.context.recentTurns.suffix(4) {
                let speaker = message.author == .user ? "User" : "Assistant"
                lines.append("\(speaker): \(message.text)")
            }
            lines.append("")
        }
        lines.append("User's message: \(input.request.normalizedText)")
        return lines.joined(separator: "\n")
    }
}
