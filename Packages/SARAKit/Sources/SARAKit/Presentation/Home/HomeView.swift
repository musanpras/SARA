import SwiftUI
import SARACore

/// SARA's single screen: identity, transcript, state, and the two input paths.
public struct HomeView: View {
    @State private var viewModel: ConversationViewModel

    public init(viewModel: ConversationViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ZStack {
            SARATheme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ConversationView(transcript: viewModel.transcript)
                controls
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("SARA")
                .font(SARATheme.Typography.identity)
                .foregroundStyle(SARATheme.Palette.primaryText)
                .kerning(3)

            Spacer()

            Button {
                viewModel.setSpeaksResponses(!viewModel.speaksResponses)
            } label: {
                Image(systemName: viewModel.speaksResponses ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SARATheme.Palette.secondaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.speaksResponses ? "Mute SARA's voice" : "Unmute SARA's voice")

            StateIndicator(state: viewModel.state)
        }
        .padding(.horizontal, SARATheme.Metrics.gutter)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if case .confirming = viewModel.state {
                confirmationActions
            }

            if !viewModel.liveTranscript.isEmpty {
                liveTranscriptView
            }

            if viewModel.supportsVoice {
                PushToTalkButton(
                    state: viewModel.state,
                    onPressStart: { viewModel.beginListening() },
                    onPressEnd: { viewModel.endListening() }
                )
            }

            TextInputBar(
                text: $viewModel.draftText,
                isEnabled: viewModel.canSubmit,
                onSubmit: { Task { await viewModel.submitDraft() } }
            )
        }
        .padding(.horizontal, SARATheme.Metrics.gutter)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: viewModel.liveTranscript.isEmpty)
    }

    /// Explicit agreement for a destructive or consequential action, one tap
    /// away but never the default.
    private var confirmationActions: some View {
        HStack(spacing: 10) {
            Button("Yes, go ahead") {
                Task { await viewModel.submit(text: "yes", source: .text, confidence: nil) }
            }
            .buttonStyle(ConfirmationButtonStyle(tint: SARATheme.Palette.caution))

            Button("No") {
                Task { await viewModel.submit(text: "no", source: .text, confidence: nil) }
            }
            .buttonStyle(ConfirmationButtonStyle(tint: SARATheme.Palette.secondaryText))
        }
    }

    private var liveTranscriptView: some View {
        Text(viewModel.liveTranscript)
            .font(SARATheme.Typography.body)
            .foregroundStyle(SARATheme.Palette.secondaryText)
            .italic()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: SARATheme.Metrics.cornerRadius, style: .continuous)
                    .fill(SARATheme.Palette.surface)
            )
            .transition(.opacity)
            .accessibilityLabel("Hearing: \(viewModel.liveTranscript)")
    }
}

private struct ConfirmationButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SARATheme.Typography.state)
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(SARATheme.Palette.surface)
                    .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
