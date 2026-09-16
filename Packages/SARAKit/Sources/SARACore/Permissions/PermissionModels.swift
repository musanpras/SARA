import Foundation

/// Capabilities SARA asks for, requested progressively — only at the moment a
/// request actually needs one.
public enum PermissionCapability: String, Hashable, Sendable, CaseIterable {
    case calendar
    case reminders
    case microphone
    case speechRecognition

    /// Shown before the system dialog, so the user knows why SARA is asking.
    public var rationale: String {
        switch self {
        case .calendar:
            "SARA needs access to your calendar to do that."
        case .reminders:
            "SARA needs access to your reminders to do that."
        case .microphone:
            "SARA needs the microphone to hear you."
        case .speechRecognition:
            "SARA needs speech recognition to understand what you say."
        }
    }
}

/// Normalised authorization state, shared by every capability.
public enum PermissionStatus: Hashable, Sendable {
    /// Never asked. SARA may prompt.
    case notDetermined
    /// Full read and write access.
    case authorized
    /// EventKit's write-only calendar mode: SARA can add events but cannot
    /// search, update or delete, so most requests still fail and must say why.
    case writeOnly
    case denied
    /// Blocked by device policy; asking again will not help.
    case restricted

    public var canRead: Bool { self == .authorized }
    public var canWrite: Bool { self == .authorized || self == .writeOnly }
    public var isPromptable: Bool { self == .notDetermined }
}

/// A permission problem stated plainly enough to show the user.
public struct PermissionError: Error, Hashable, Sendable {
    public let capability: PermissionCapability
    public let status: PermissionStatus

    public init(capability: PermissionCapability, status: PermissionStatus) {
        self.capability = capability
        self.status = status
    }

    public var userMessage: String {
        switch status {
        case .denied:
            "I don't have access to your \(noun). You can turn it on in Settings."
        case .restricted:
            "Access to your \(noun) is restricted on this device, so I can't do that."
        case .writeOnly:
            "I only have permission to add to your \(noun), not to read or change it. Full access is in Settings."
        case .notDetermined, .authorized:
            "I need access to your \(noun) first."
        }
    }

    private var noun: String {
        switch capability {
        case .calendar: "calendar"
        case .reminders: "reminders"
        case .microphone: "microphone"
        case .speechRecognition: "speech recognition"
        }
    }
}
