import Foundation

/// Finds date, time, duration, alert and recurrence phrases in English text.
///
/// It reports *what was said*, as a spec plus the text range it occupied, and
/// resolves nothing. `TemporalEngine` turns the spec into a real moment. That
/// split keeps interpretation replaceable and arithmetic deterministic.
struct TemporalPhraseParser: Sendable {
    struct Match<Value: Sendable>: Sendable {
        let value: Value
        let range: Range<String.Index>
    }

    // MARK: - Recurrence

    /// Matched before dates, so "every Monday" is not mistaken for "Monday".
    func findRecurrence(in text: String) -> Match<RecurrenceRule>? {
        if let match = text.firstMatch(of: /\bevery\s+(week\s?day|weekday)s?\b/.ignoresCase()) {
            return Match(value: .everyWeekday, range: match.range)
        }
        if let match = text.firstMatch(of: /\bevery\s+day\b|\bdaily\b/.ignoresCase()) {
            return Match(value: .everyDay, range: match.range)
        }
        if let match = text.firstMatch(
            of: /\b(?:the\s+)?(first|second|third|fourth|last)\s+(\w+)\s+of\s+(?:every|each)\s+month\b/.ignoresCase()
        ) {
            let ordinal = Self.ordinals[String(match.1).lowercased()]
            let weekday = Self.weekdays[String(match.2).lowercased()]
            if let ordinal, let weekday {
                return Match(value: .monthly(ordinal: ordinal, weekday: weekday), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\bevery\s+(other|\d+|two|three|four)\s+weeks?\b/.ignoresCase()) {
            let token = String(match.1).lowercased()
            let interval = token == "other" ? 2 : (Self.numberWords[token] ?? Int(token) ?? 2)
            return Match(value: .everyNWeeks(interval), range: match.range)
        }
        if let match = text.firstMatch(of: /\bevery\s+(\w+day)\b/.ignoresCase()) {
            if let weekday = Self.weekdays[String(match.1).lowercased()] {
                return Match(value: .every(weekday), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\bevery\s+month\b|\bmonthly\b/.ignoresCase()) {
            return Match(value: RecurrenceRule(frequency: .monthly), range: match.range)
        }
        return nil
    }

    // MARK: - Days

    func findDay(in text: String) -> Match<DaySpec>? {
        if let match = text.firstMatch(of: /\bday\s+after\s+tomorrow\b/.ignoresCase()) {
            return Match(value: .daysFromToday(2), range: match.range)
        }
        if let match = text.firstMatch(of: /\btomorrow\b/.ignoresCase()) {
            return Match(value: .tomorrow, range: match.range)
        }
        if let match = text.firstMatch(of: /\byesterday\b/.ignoresCase()) {
            return Match(value: .yesterday, range: match.range)
        }
        if let match = text.firstMatch(of: /\b(today|tonight|this\s+(?:morning|afternoon|evening))\b/.ignoresCase()) {
            return Match(value: .today, range: match.range)
        }
        if let match = text.firstMatch(of: /\bin\s+(\d+|\w+)\s+(day|week)s?\b/.ignoresCase()) {
            let token = String(match.1).lowercased()
            if let count = Int(token) ?? Self.numberWords[token] {
                let spec: DaySpec = match.2 == "day" ? .daysFromToday(count) : .weeksFromToday(count)
                return Match(value: spec, range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\b(next|this|last)\s+week\b/.ignoresCase()) {
            let offset = switch String(match.1).lowercased() {
            case "next": 1
            case "last": -1
            default: 0
            }
            return Match(value: .weeksFromToday(offset), range: match.range)
        }
        if let match = text.firstMatch(of: /\b(next|this|last)\s+(\w+)\b/.ignoresCase()) {
            if let weekday = Self.weekdays[String(match.2).lowercased()] {
                let qualifier: WeekdayQualifier = switch String(match.1).lowercased() {
                case "next": .next
                case "last": .previous
                default: .thisWeek
                }
                return Match(value: .weekday(weekday, qualifier), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\b(?:on\s+)?(\w+day)\b/.ignoresCase()) {
            if let weekday = Self.weekdays[String(match.1).lowercased()] {
                return Match(value: .weekday(weekday, .upcoming), range: match.range)
            }
        }
        // "on 3 October" / "on October 3rd"
        if let match = text.firstMatch(of: /\b(?:on\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(\w+)\b/.ignoresCase()) {
            if let month = Self.months[String(match.2).lowercased()], let day = Int(match.1) {
                return Match(value: .explicit(year: nil, month: month, day: day), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\b(?:on\s+)?(\w+)\s+(\d{1,2})(?:st|nd|rd|th)?\b/.ignoresCase()) {
            if let month = Self.months[String(match.1).lowercased()], let day = Int(match.2) {
                return Match(value: .explicit(year: nil, month: month, day: day), range: match.range)
            }
        }
        return nil
    }

    // MARK: - Times

    func findTime(in text: String) -> Match<TimeSpec>? {
        if let match = text.firstMatch(of: /\bin\s+(\d+|\w+)\s+(hour|minute|min)s?\b/.ignoresCase()) {
            let token = String(match.1).lowercased()
            if let count = Int(token) ?? Self.numberWords[token] {
                let unit: Double = match.2 == "hour" ? 3600 : 60
                return Match(value: .offsetFromNow(seconds: Double(count) * unit), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\bat\s+(\d{1,2})[:.](\d{2})\s*(am|pm)?\b/.ignoresCase()) {
            if let hour = Int(match.1), let minute = Int(match.2) {
                let adjusted = Self.applyMeridiem(hour: hour, meridiem: match.3.map(String.init))
                return Match(value: .clock(hour: adjusted, minute: minute), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\bat\s+(\d{1,2})\s*(am|pm)\b/.ignoresCase()) {
            if let hour = Int(match.1) {
                let adjusted = Self.applyMeridiem(hour: hour, meridiem: String(match.2))
                return Match(value: .clock(hour: adjusted, minute: 0), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\b(\d{1,2})\s*(am|pm)\b/.ignoresCase()) {
            if let hour = Int(match.1) {
                let adjusted = Self.applyMeridiem(hour: hour, meridiem: String(match.2))
                return Match(value: .clock(hour: adjusted, minute: 0), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\bat\s+(\d{1,2})\b/.ignoresCase()) {
            if let hour = Int(match.1), (0...23).contains(hour) {
                return Match(value: .clock(hour: hour, minute: 0), range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\b(noon|midday)\b/.ignoresCase()) {
            return Match(value: .part(.noon), range: match.range)
        }
        if let match = text.firstMatch(of: /\bmidnight\b/.ignoresCase()) {
            return Match(value: .part(.midnight), range: match.range)
        }
        if let match = text.firstMatch(of: /\b(?:this\s+)?(morning|afternoon|evening)\b/.ignoresCase()) {
            let part: DayPart = switch String(match.1).lowercased() {
            case "morning": .morning
            case "afternoon": .afternoon
            default: .evening
            }
            return Match(value: .part(part), range: match.range)
        }
        if let match = text.firstMatch(of: /\btonight\b/.ignoresCase()) {
            return Match(value: .part(.night), range: match.range)
        }
        return nil
    }

    // MARK: - Durations and alerts

    func findDuration(in text: String) -> Match<Int>? {
        if let match = text.firstMatch(of: /\bfor\s+(?:an?\s+)?half\s+an?\s+hour\b/.ignoresCase()) {
            return Match(value: 30, range: match.range)
        }
        if let match = text.firstMatch(of: /\bfor\s+(\d+(?:\.\d+)?|\w+)\s+(hour|hr|minute|min)s?\b/.ignoresCase()) {
            let token = String(match.1).lowercased()
            let amount = Double(token) ?? Self.numberWords[token].map(Double.init)
            if let amount {
                let minutes = match.2 == "hour" || match.2 == "hr"
                    ? Int((amount * 60).rounded())
                    : Int(amount.rounded())
                return Match(value: minutes, range: match.range)
            }
        }
        if let match = text.firstMatch(of: /\bfor\s+an?\s+(hour|hr)\b/.ignoresCase()) {
            return Match(value: 60, range: match.range)
        }
        return nil
    }

    /// "remind me 30 minutes before" — the number of minutes ahead of the start.
    func findAlert(in text: String) -> Match<Int>? {
        // The surrounding "and remind me" is consumed too, so removing the
        // match leaves a clean title behind.
        if let match = text.firstMatch(
            of: /(?:\s*\band\b)?\s*(?:remind\s+me\s+)?\b(\d+|\w+)\s+(hour|minute|min)s?\s+(?:before|ahead)\b/.ignoresCase()
        ) {
            let token = String(match.1).lowercased()
            if let amount = Int(token) ?? Self.numberWords[token] {
                return Match(value: match.2 == "hour" ? amount * 60 : amount, range: match.range)
            }
        }
        return nil
    }

    // MARK: - Containers

    /// "on my Work calendar", "in the Groceries list".
    ///
    /// Only the explicit forms are matched. A bare "in Home" is far more often
    /// part of a title than a calendar name, and guessing wrong would file the
    /// event somewhere the user cannot find it.
    func findContainerName(in text: String) -> Match<String>? {
        guard let match = text.firstMatch(
            of: /\s*\b(?:on|in|to)\s+(?:my\s+|the\s+)?([\w'&-]+(?:\s+[\w'&-]+)?)\s+(calendar|list)\b/.ignoresCase()
        ) else { return nil }

        let name = String(match.1).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return Match(value: name, range: match.range)
    }

    // MARK: - Vocabulary

    private static func applyMeridiem(hour: Int, meridiem: String?) -> Int {
        guard let meridiem = meridiem?.lowercased() else { return hour }
        if meridiem == "pm", hour < 12 { return hour + 12 }
        if meridiem == "am", hour == 12 { return 0 }
        return hour
    }

    static let weekdays: [String: Weekday] = [
        "sunday": .sunday, "sun": .sunday,
        "monday": .monday, "mon": .monday,
        "tuesday": .tuesday, "tue": .tuesday, "tues": .tuesday,
        "wednesday": .wednesday, "wed": .wednesday,
        "thursday": .thursday, "thu": .thursday, "thurs": .thursday,
        "friday": .friday, "fri": .friday,
        "saturday": .saturday, "sat": .saturday,
    ]

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "forty-five": 45,
        "fortyfive": 45, "sixty": 60, "ninety": 90,
    ]

    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "last": -1,
    ]
}
