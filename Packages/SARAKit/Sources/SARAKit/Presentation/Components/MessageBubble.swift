import SwiftUI
import SARACore

struct MessageBubble: View {
    let message: ConversationMessage

    private var isUser: Bool { message.author == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(SARATheme.Typography.body)
                    .foregroundStyle(SARATheme.Palette.primaryText)
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(bubbleBackground)
                    .overlay(alignment: .leading) { kindStripe }
                    .clipShape(RoundedRectangle(cornerRadius: SARATheme.Metrics.bubbleRadius, style: .continuous))
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You said: \(message.text)" : "SARA said: \(message.text)")
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: SARATheme.Metrics.bubbleRadius, style: .continuous)
            .fill(isUser ? SARATheme.Palette.surfaceRaised : SARATheme.Palette.surface)
    }

    /// A coloured edge, not a coloured bubble: destructive and failed turns must
    /// read differently at a glance without shouting.
    @ViewBuilder
    private var kindStripe: some View {
        if !isUser, let accent = message.kind.accentColor {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
        }
    }
}
