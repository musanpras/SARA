import SwiftUI
import SARACore

/// Push-to-talk control. Press and hold to talk, release to send.
///
/// The gesture contract lives here; the actual recogniser is injected later, so
/// this component stays testable and provider-agnostic.
struct PushToTalkButton: View {
    let state: AssistantState
    let onPressStart: () -> Void
    let onPressEnd: () -> Void

    @State private var isPressed = false

    private var isListening: Bool { state == .listening }
    private var isEnabled: Bool { state.acceptsInput || isListening }

    var body: some View {
        ZStack {
            Circle()
                .fill(isListening ? SARATheme.Palette.listening : SARATheme.Palette.accent)
                .frame(width: 72, height: 72)
                .shadow(color: (isListening ? SARATheme.Palette.listening : SARATheme.Palette.accent).opacity(0.35),
                        radius: isPressed ? 22 : 12)
                .scaleEffect(isPressed ? 1.08 : 1.0)

            Image(systemName: isListening ? "waveform" : "mic.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SARATheme.Palette.background)
        }
        .opacity(isEnabled ? 1.0 : 0.4)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .animation(.easeInOut(duration: 0.2), value: isListening)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !isPressed else { return }
                    isPressed = true
                    onPressStart()
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    onPressEnd()
                }
        )
        .disabled(!isEnabled)
        .accessibilityLabel("Push to talk")
        .accessibilityHint("Press and hold to speak to SARA")
    }
}
