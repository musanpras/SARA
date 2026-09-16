import Foundation

/// Why a temporal expression could not be turned into a single moment.
public enum TemporalError: Error, Hashable, Sendable {
    /// The phrase has more than one defensible reading, so SARA must ask.
    case ambiguous(question: String, candidates: [Date])
    /// The components do not describe a real moment (e.g. 31 February, 25:00).
    case impossibleDate(String)
    /// A time was required but the user never gave one.
    case timeRequired
    /// A day was required but the user never gave one.
    case dayRequired

    public var userMessage: String {
        switch self {
        case .ambiguous(let question, _): question
        case .impossibleDate(let detail): "That date doesn't exist — \(detail)."
        case .timeRequired: "What time should I use?"
        case .dayRequired: "Which day should I use?"
        }
    }
}

/// A resolved moment, with the provenance the rest of the pipeline needs.
public struct ResolvedDateTime: Hashable, Sendable {
    public let date: Date
    /// False when the time came from a default rather than from the user.
    /// Response wording and reminder alerts both depend on this.
    public let timeWasSpecified: Bool

    public init(date: Date, timeWasSpecified: Bool) {
        self.date = date
        self.timeWasSpecified = timeWasSpecified
    }
}

/// Deterministic date arithmetic for SARA.
///
/// Language interpretation happens elsewhere; this type only turns a structured
/// `DateTimeSpec` into a real moment using the user's calendar and time zone,
/// and refuses — rather than guesses — when a phrase is genuinely ambiguous.
public struct TemporalEngine: Sendable {
    private let dateProvider: DateProvider
    public let preferences: TemporalPreferences

    public init(dateProvider: DateProvider, preferences: TemporalPreferences = .default) {
        self.dateProvider = dateProvider
        self.preferences = preferences
    }

    public var now: Date { dateProvider.now }
    public var calendar: Calendar { dateProvider.calendar }

    // MARK: - Resolution

    /// Resolves a spec to a single moment.
    ///
    /// - Parameter defaultTime: applied when the spec states no time. Passing
    ///   `nil` makes a missing time an error, which is what event creation
    ///   wants: it must ask rather than assume.
    public func resolve(
        _ spec: DateTimeSpec,
        defaultTime: (hour: Int, minute: Int)? = nil
    ) throws -> ResolvedDateTime {
        guard let day = spec.day else { throw TemporalError.dayRequired }
        return try resolve(day: day, time: spec.time, defaultTime: defaultTime)
    }

    /// Resolves a time against a day supplied by the caller, used when a change
    /// names a new time but keeps the record's existing date.
    public func resolve(
        day: DaySpec,
        time: TimeSpec,
        defaultTime: (hour: Int, minute: Int)? = nil
    ) throws -> ResolvedDateTime {
        let spec = DateTimeSpec(day: day, time: time)
        // "In two hours" is measured from now, so it ignores the day entirely
        // and may legitimately land on a different date.
        if case .offsetFromNow(let seconds) = spec.time {
            return ResolvedDateTime(date: now.addingTimeInterval(seconds), timeWasSpecified: true)
        }

        let day = try resolveDay(day)

        switch spec.time {
        case .clock(let hour, let minute):
            let date = try apply(hour: hour, minute: minute, to: day)
            return ResolvedDateTime(date: date, timeWasSpecified: true)

        case .part(let part):
            let date = try apply(hour: preferences.hour(for: part), minute: 0, to: day)
            return ResolvedDateTime(date: date, timeWasSpecified: true)

        case .unspecified:
            guard let defaultTime else { throw TemporalError.timeRequired }
            let date = try apply(hour: defaultTime.hour, minute: defaultTime.minute, to: day)
            return ResolvedDateTime(date: date, timeWasSpecified: false)

        case .offsetFromNow:
            preconditionFailure("Handled above")
        }
    }

    /// The whole-day interval a `DaySpec` covers, used for searches like
    /// "what's on my calendar tomorrow?".
    public func dayInterval(for day: DaySpec) throws -> DateInterval {
        let start = try resolveDay(day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw TemporalError.impossibleDate("the day after could not be computed")
        }
        return DateInterval(start: start, end: end)
    }

    /// Start-of-day for a resolved day, in the user's time zone.
    public func resolveDay(_ day: DaySpec) throws -> Date {
        let today = calendar.startOfDay(for: now)

        switch day {
        case .today:
            return today
        case .tomorrow:
            return try adding(days: 1, to: today)
        case .yesterday:
            return try adding(days: -1, to: today)
        case .daysFromToday(let offset):
            return try adding(days: offset, to: today)
        case .weeksFromToday(let offset):
            return try adding(days: offset * 7, to: today)
        case .weekday(let weekday, let qualifier):
            return try resolveWeekday(weekday, qualifier: qualifier, today: today)
        case .explicit(let year, let month, let day):
            return try resolveExplicit(year: year, month: month, day: day, today: today)
        }
    }

    // MARK: - Weekdays

    private func resolveWeekday(
        _ weekday: Weekday,
        qualifier: WeekdayQualifier,
        today: Date
    ) throws -> Date {
        switch qualifier {
        case .upcoming:
            return try nextOccurrence(of: weekday, onOrAfter: today)

        case .thisWeek:
            return try occurrence(of: weekday, inWeekContaining: today)

        case .previous:
            let upcoming = try nextOccurrence(of: weekday, onOrAfter: today)
            return upcoming == today
                ? try adding(days: -7, to: today)
                : try adding(days: -7, to: upcoming)

        case .next:
            // "Next Friday" means either the coming Friday or the Friday of the
            // following week depending on the speaker. When those differ SARA
            // asks instead of silently picking, because the two readings can be
            // a week apart.
            let soonest = try nextOccurrence(of: weekday, onOrAfter: try adding(days: 1, to: today))
            let followingWeek = try occurrence(
                of: weekday,
                inWeekContaining: try adding(days: 7, to: today)
            )

            if soonest == followingWeek { return soonest }
            throw TemporalError.ambiguous(
                question: ambiguityQuestion(for: [soonest, followingWeek]),
                candidates: [soonest, followingWeek]
            )
        }
    }

    /// The first `weekday` at or after `date`, at start of day.
    private func nextOccurrence(of weekday: Weekday, onOrAfter date: Date) throws -> Date {
        let current = calendar.component(.weekday, from: date)
        let delta = (weekday.calendarValue - current + 7) % 7
        return try adding(days: delta, to: date)
    }

    /// The `weekday` inside the calendar week containing `date`, honouring the
    /// locale's first day of the week.
    private func occurrence(of weekday: Weekday, inWeekContaining date: Date) throws -> Date {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            throw TemporalError.impossibleDate("the week could not be determined")
        }
        let weekStart = calendar.startOfDay(for: weekInterval.start)
        let startWeekday = calendar.component(.weekday, from: weekStart)
        let delta = (weekday.calendarValue - startWeekday + 7) % 7
        return try adding(days: delta, to: weekStart)
    }

    // MARK: - Explicit dates

    private func resolveExplicit(year: Int?, month: Int, day: Int, today: Date) throws -> Date {
        guard (1...12).contains(month) else {
            throw TemporalError.impossibleDate("there is no month \(month)")
        }
        guard (1...31).contains(day) else {
            throw TemporalError.impossibleDate("there is no day \(day)")
        }

        if let year {
            return try makeDate(year: year, month: month, day: day)
        }

        // No year stated: the nearest future occurrence, which is what people
        // mean by "on the 3rd of March".
        let currentYear = calendar.component(.year, from: today)
        let thisYear = try? makeDate(year: currentYear, month: month, day: day)
        if let thisYear, thisYear >= today { return thisYear }
        return try makeDate(year: currentYear + 1, month: month, day: day)
    }

    private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let date = calendar.date(from: components) else {
            throw TemporalError.impossibleDate("\(year)-\(month)-\(day) is not a real date")
        }
        // `Calendar` rolls 31 February into March rather than failing, so the
        // round-trip below is what actually rejects impossible dates.
        let readBack = calendar.dateComponents([.year, .month, .day], from: date)
        guard readBack.year == year, readBack.month == month, readBack.day == day else {
            throw TemporalError.impossibleDate("\(month)/\(day) doesn't exist in \(year)")
        }
        return date
    }

    // MARK: - Helpers

    private func apply(hour: Int, minute: Int, to day: Date) throws -> Date {
        guard (0...23).contains(hour) else {
            throw TemporalError.impossibleDate("there is no hour \(hour)")
        }
        guard (0...59).contains(minute) else {
            throw TemporalError.impossibleDate("there is no minute \(minute)")
        }
        guard let date = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else {
            // Daylight-saving transitions can delete a wall-clock hour.
            throw TemporalError.impossibleDate("\(hour):\(String(format: "%02d", minute)) doesn't exist on that day")
        }
        return date
    }

    private func adding(days: Int, to date: Date) throws -> Date {
        guard let result = calendar.date(byAdding: .day, value: days, to: date) else {
            throw TemporalError.impossibleDate("the date could not be shifted by \(days) days")
        }
        return calendar.startOfDay(for: result)
    }

    /// Phrases the ambiguity as a question the user can answer in one word.
    private func ambiguityQuestion(for candidates: [Date]) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")

        let rendered = candidates.map(formatter.string(from:))
        guard rendered.count == 2 else {
            return "Which date do you mean?"
        }
        return "Do you mean \(rendered[0]) or \(rendered[1])?"
    }
}
