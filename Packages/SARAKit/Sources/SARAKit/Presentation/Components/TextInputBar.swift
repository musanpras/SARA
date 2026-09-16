import SwiftUI
import SARACore

/// Text entry, the equal-footing alternative to voice. Both feed one pipeline.
struct TextInputBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    private var canSubmit: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Type a request", text: $text, axis: .vertical)
                .font(SARATheme.Typography.body)
                .foregroundStyle(SARATheme.Palette.primaryText)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .disabled(!isEnabled)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canSubmit ? SARATheme.Palette.accent : SARATheme.Palette.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: SARATheme.Metrics.cornerRadius, style: .continuous)
                .fill(SARATheme.Palette.surface)
        )
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }
}
