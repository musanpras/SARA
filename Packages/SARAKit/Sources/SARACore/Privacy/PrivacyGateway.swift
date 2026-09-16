import Foundation

/// Narrows what a provider is told, based on where it runs.
///
/// On-device providers see the full working context. Anything off device gets
/// the minimum the task needs, with obvious identifiers redacted — "use the
/// most capable model necessary, but expose the minimum personal data
/// required".
public struct PrivacyGateway: Sendable {
    /// How many recent turns an off-device provider may see.
    public let offDeviceTurnLimit: Int

    public init(offDeviceTurnLimit: Int = 4) {
        self.offDeviceTurnLimit = offDeviceTurnLimit
    }

    public func minimize(_ input: AIInput, for provider: any AIProvider) -> AIInput {
        guard !provider.capabilities.isOnDevice else { return input }

        var context = input.context
        context.recentTurns = context.recentTurns
            .suffix(offDeviceTurnLimit)
            .map { message in
                ConversationMessage(
                    id: message.id,
                    author: message.author,
                    text: Self.redact(message.text),
                    kind: message.kind,
                    timestamp: message.timestamp
                )
            }

        // Concrete records stay local. A cloud model is asked what the user
        // means, never handed the calendar to read.
        context.references = ReferenceContext(
            presentedEvents: [],
            presentedReminders: [],
            lastTouchedEvent: nil,
            lastTouchedReminder: nil
        )

        let request = UserRequest(
            id: input.request.id,
            text: Self.redact(input.request.text),
            source: input.request.source,
            transcriptionConfidence: input.request.transcriptionConfidence,
            timestamp: input.request.timestamp
        )
        return AIInput(request: request, context: context)
    }

    /// Masks the identifiers that most often appear in calendar text.
    ///
    /// This is data minimisation, not anonymisation: it removes the obvious
    /// contact details, and the surrounding policy keeps genuinely sensitive
    /// requests on device in the first place.
    static func redact(_ text: String) -> String {
        var result = text
        result = result.replacing(
            /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/.ignoresCase(),
            with: "[email]"
        )
        result = result.replacing(
            /\+?\d[\d\s().-]{7,}\d/,
            with: "[phone]"
        )
        result = result.replacing(
            /\bhttps?:\/\/\S+/.ignoresCase(),
            with: "[link]"
        )
        return result
    }
}
