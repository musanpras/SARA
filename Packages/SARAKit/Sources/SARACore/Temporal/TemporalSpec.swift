import Foundation

/// A day of the week, stored in `Calendar`'s 1-based numbering (1 = Sunday).
public enum Weekday: Int, Hashable, Sendable, Codable, CaseIterable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var calendarValue: Int { rawValue }

    public var isWeekend: Bool { self == .saturday || self == .sunday }

    public static let weekdays: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]
}

/// Which occurrence of a named weekday the user meant.
public enum WeekdayQualifier: Hashable, Sendable, Codable {
    /// "on Friday" — the soonest one, today included if it has not passed.
    case upcoming
    /// "this Friday" — the one in the current week.
    case thisWeek
    /// "next Friday" — deliberately ambiguous in everyday English, so the
    /// engine surfaces both readings rather than choosing one.
    case next
    /// "last Friday" — the most recent one already past.
    case previous
}

/// Named parts of the day. Concrete hours come from `TemporalPreferences` so
/// the user's own sense of "evening" can be honoured later.
public enum DayPart: String, Hashable, Sendable, Codable, CaseIterable {
    case morning
    case afternoon
    case evening
    case night
    case noon
    case midnight
}

/// Which calendar day the user meant, before any clock time is applied.
public enum DaySpec: Hashable, Sendable, Codable {
    case today
    case tomorrow
    case yesterday
    /// Signed offset in days from today.
    case daysFromToday(Int)
    case weeksFromToday(Int)
    case weekday(Weekday, WeekdayQualifier)
    /// A stated calendar date. A missing year means "the next such date".
    case explicit(year: Int?, month: Int, day: Int)
}

/// Which clock time the user meant, if any.
public enum TimeSpec: Hashable, Sendable, Codable {
    /// An explicit wall-clock time.
    case clock(hour: Int, minute: Int)
    /// "this afternoon", "tonight".
    case part(DayPart)
    /// "in two hours" — measured from now, so it can cross midnight.
    case offsetFromNow(seconds: TimeInterval)
    /// Nothing was said about time. The caller decides whether to ask or apply
    /// a default; the engine never invents one.
    case unspecified
}

/// A date and time as the language layer describes it, before Swift resolves it.
///
/// The AI (or the local parser) may only produce one of these. It never
/// produces a `Date` directly, so every final moment is computed and validated
/// by `TemporalEngine`.
public struct DateTimeSpec: Hashable, Sendable, Codable {
    /// `nil` when the user named no day. For a new event that means SARA must
    /// ask; for a change it means "keep the day it is already on".
    public var day: DaySpec?
    public var time: TimeSpec

    public init(day: DaySpec?, time: TimeSpec = .unspecified) {
        self.day = day
        self.time = time
    }
}

/// Defaults the engine applies when the user left something unsaid.
public struct TemporalPreferences: Hashable, Sendable, Codable {
    public var morningHour: Int
    public var afternoonHour: Int
    public var eveningHour: Int
    public var nightHour: Int
    /// Applied to reminders whose day is known but whose time is not.
    public var defaultReminderHour: Int
    public var defaultReminderMinute: Int
    /// Applied to events created without a stated duration.
    public var defaultEventDuration: TimeInterval

    public init(
        morningHour: Int = 9,
        afternoonHour: Int = 14,
        eveningHour: Int = 19,
        nightHour: Int = 21,
        defaultReminderHour: Int = 9,
        defaultReminderMinute: Int = 0,
        defaultEventDuration: TimeInterval = 3600
    ) {
        self.morningHour = morningHour
        self.afternoonHour = afternoonHour
        self.eveningHour = eveningHour
        self.nightHour = nightHour
        self.defaultReminderHour = defaultReminderHour
        self.defaultReminderMinute = defaultReminderMinute
        self.defaultEventDuration = defaultEventDuration
    }

    public static let `default` = TemporalPreferences()

    func hour(for part: DayPart) -> Int {
        switch part {
        case .morning: morningHour
        case .afternoon: afternoonHour
        case .evening: eveningHour
        case .night: nightHour
        case .noon: 12
        case .midnight: 0
        }
    }
}
