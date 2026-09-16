import SwiftUI
import SARACore

/// Scrolling transcript. Empty state carries the whole first-run experience:
/// one question, no permission prompts, no configuration.
struct ConversationView: View {
    let transcript: ConversationTranscript

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SARATheme.Metrics.stackSpacing) {
                    if transcript.isEmpty {
                        emptyState
                    } else {
                        ForEach(transcript.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, SARATheme.Metrics.gutter)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: transcript.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("How can I help?")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(SARATheme.Palette.primaryText)

            Text("Hold the microphone, or type below.")
                .font(SARATheme.Typography.caption)
                .foregroundStyle(SARATheme.Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
