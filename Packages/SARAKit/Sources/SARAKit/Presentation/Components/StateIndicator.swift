import SwiftUI
import SARACore

/// Small always-visible badge telling the user exactly which state SARA is in.
struct StateIndicator: View {
    let state: AssistantState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.indicatorColor)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse && state.indicatorPulses ? 1.45 : 1.0)
                .opacity(pulse && state.indicatorPulses ? 0.55 : 1.0)
                .animation(
                    state.indicatorPulses
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

            Text(state.displayLabel)
                .font(SARATheme.Typography.state)
                .foregroundStyle(SARATheme.Palette.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(SARATheme.Palette.surface)
        )
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SARA status: \(state.displayLabel)")
    }
}
