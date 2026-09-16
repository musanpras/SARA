import Foundation

/// User-adjustable defaults SARA applies instead of asking.
///
/// Anything here is safe to assume; anything not here is asked about. The split
/// is deliberate — defaults cover convenience, never the facts that decide
/// which record is touched.
public struct SARAPreferences: Hashable, Sendable, Codable {
    public var temporal: TemporalPreferences
    /// Alert applied to new events when the user did not ask for one.
    /// `nil` means no alert, which is the safe default: SARA does not create
    /// unexpected notifications.
    public var defaultEventAlertMinutes: Int?
    public var defaultReminderAlertMinutes: Int?
    /// Calendar to prefer when the user names none and several are writable.
    public var preferredCalendarName: String?
    public var preferredReminderListName: String?
    /// How far around today SARA searches when a change names no date.
    public var openEndedSearchDaysBack: Int
    public var openEndedSearchDaysForward: Int
    /// Whether SARA speaks its answers aloud. Voice input is unaffected.
    public var speaksResponses: Bool

    public init(
        temporal: TemporalPreferences = .default,
        defaultEventAlertMinutes: Int? = nil,
        defaultReminderAlertMinutes: Int? = nil,
        preferredCalendarName: String? = nil,
        preferredReminderListName: String? = nil,
        openEndedSearchDaysBack: Int = 1,
        openEndedSearchDaysForward: Int = 60,
        speaksResponses: Bool = true
    ) {
        self.temporal = temporal
        self.defaultEventAlertMinutes = defaultEventAlertMinutes
        self.defaultReminderAlertMinutes = defaultReminderAlertMinutes
        self.preferredCalendarName = preferredCalendarName
        self.preferredReminderListName = preferredReminderListName
        self.openEndedSearchDaysBack = openEndedSearchDaysBack
        self.openEndedSearchDaysForward = openEndedSearchDaysForward
        self.speaksResponses = speaksResponses
    }

    public static let `default` = SARAPreferences()

    /// Decoding tolerates missing keys so a preferences blob written by an
    /// older build still loads, with new settings taking their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SARAPreferences.default

        temporal = try container.decodeIfPresent(TemporalPreferences.self, forKey: .temporal)
            ?? fallback.temporal
        defaultEventAlertMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultEventAlertMinutes)
        defaultReminderAlertMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultReminderAlertMinutes)
        preferredCalendarName = try container.decodeIfPresent(String.self, forKey: .preferredCalendarName)
        preferredReminderListName = try container.decodeIfPresent(String.self, forKey: .preferredReminderListName)
        openEndedSearchDaysBack = try container.decodeIfPresent(Int.self, forKey: .openEndedSearchDaysBack)
            ?? fallback.openEndedSearchDaysBack
        openEndedSearchDaysForward = try container.decodeIfPresent(Int.self, forKey: .openEndedSearchDaysForward)
            ?? fallback.openEndedSearchDaysForward
        speaksResponses = try container.decodeIfPresent(Bool.self, forKey: .speaksResponses)
            ?? fallback.speaksResponses
    }
}
