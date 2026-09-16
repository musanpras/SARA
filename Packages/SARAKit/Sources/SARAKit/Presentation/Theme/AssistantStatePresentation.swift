import SwiftUI
import SARACore

/// Maps domain state onto its visual treatment.
///
/// Keeping this out of the views means the state machine stays the only place
/// that decides what SARA is doing; the UI merely renders it.
extension AssistantState {
    var displayLabel: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .processing: "Thinking"
        case .clarifying: "Needs a detail"
        case .confirming: "Awaiting confirmation"
        case .executing(let description): description
        case .success: "Done"
        case .failed: "Failed"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .idle: SARATheme.Palette.secondaryText
        case .listening: SARATheme.Palette.listening
        case .processing, .executing: SARATheme.Palette.accent
        case .clarifying, .confirming: SARATheme.Palette.caution
        case .success: SARATheme.Palette.success
        case .failed: SARATheme.Palette.destructive
        }
    }

    /// Whether the indicator should animate. Only genuine work pulses, so
    /// motion always means "SARA is busy".
    var indicatorPulses: Bool {
        isBusy || self == .listening
    }
}

extension ConversationMessage.Kind {
    var accentColor: Color? {
        switch self {
        case .standard: nil
        case .clarification: SARATheme.Palette.caution
        case .confirmation: SARATheme.Palette.caution
        case .success: SARATheme.Palette.success
        case .failure: SARATheme.Palette.destructive
        }
    }
}
