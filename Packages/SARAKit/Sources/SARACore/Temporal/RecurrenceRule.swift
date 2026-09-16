import Foundation

/// A repeat pattern, expressed in terms EventKit can reproduce exactly.
///
/// Natural language ("every other Monday", "first Monday of every month") is
/// interpreted into this structure by the language layer; Swift then validates
/// it and EventKit builds the real rule. Nothing here is free-form text.
public struct RecurrenceRule: Hashable, Sendable, Codable {
    public enum Frequency: String, Hashable, Sendable, Codable {
        case daily, weekly, monthly, yearly
    }

    /// When the series stops.
    public enum End: Hashable, Sendable, Codable {
        case never
        case afterOccurrences(Int)
        case onDate(Date)
    }

    public var frequency: Frequency
    /// Repeat every `interval` units. 2 with `.weekly` is "every two weeks".
    public var interval: Int
    /// Days the rule fires on. Empty means "the same day as the event".
    public var weekdays: [Weekday]
    /// Days of the month, for `.monthly` rules anchored to a date.
    public var daysOfMonth: [Int]
    /// Which occurrence within the period, e.g. 1 for "first Monday",
    /// -1 for "last Friday". Only meaningful with `weekdays`.
    public var weekNumber: Int?
    public var end: End

    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: [Weekday] = [],
        daysOfMonth: [Int] = [],
        weekNumber: Int? = nil,
        end: End = .never
    ) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.daysOfMonth = daysOfMonth
        self.weekNumber = weekNumber
        self.end = end
    }

    // MARK: - Common patterns

    public static let everyDay = RecurrenceRule(frequency: .daily)

    public static func every(_ weekday: Weekday) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, weekdays: [weekday])
    }

    /// "Every weekday" — Monday through Friday.
    public static let everyWeekday = RecurrenceRule(frequency: .weekly, weekdays: Weekday.weekdays)

    public static func everyNWeeks(_ weeks: Int, on weekdays: [Weekday] = []) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, interval: weeks, weekdays: weekdays)
    }

    /// "First Monday of every month"; pass -1 for "last".
    public static func monthly(ordinal: Int, weekday: Weekday) -> RecurrenceRule {
        RecurrenceRule(frequency: .monthly, weekdays: [weekday], weekNumber: ordinal)
    }

    // MARK: - Validation

    public enum ValidationFailure: Error, Hashable, Sendable {
        case nonPositiveInterval(Int)
        case invalidWeekNumber(Int)
        case weekNumberWithoutWeekday
        case invalidDayOfMonth(Int)
        case weekNumberOnUnsupportedFrequency(Frequency)
        case nonPositiveOccurrenceCount(Int)

        public var userMessage: String {
            switch self {
            case .nonPositiveInterval:
                "A repeat has to happen at least every one period."
            case .invalidWeekNumber:
                "I can only use the first through fifth, or the last, occurrence in a period."
            case .weekNumberWithoutWeekday:
                "I need to know which day of the week that repeat lands on."
            case .invalidDayOfMonth:
                "That day of the month doesn't exist."
            case .weekNumberOnUnsupportedFrequency:
                "That kind of repeat only works for monthly or yearly patterns."
            case .nonPositiveOccurrenceCount:
                "A repeat has to happen at least once."
            }
        }
    }

    /// Rejects rules EventKit would silently reinterpret or refuse.
    public func validate() throws {
        guard interval >= 1 else {
            throw ValidationFailure.nonPositiveInterval(interval)
        }

        if let weekNumber {
            guard (-1...5).contains(weekNumber), weekNumber != 0 else {
                throw ValidationFailure.invalidWeekNumber(weekNumber)
            }
            guard !weekdays.isEmpty else {
                throw ValidationFailure.weekNumberWithoutWeekday
            }
            guard frequency == .monthly || frequency == .yearly else {
                throw ValidationFailure.weekNumberOnUnsupportedFrequency(frequency)
            }
        }

        for day in daysOfMonth where !(-31...31).contains(day) || day == 0 {
            throw ValidationFailure.invalidDayOfMonth(day)
        }

        if case .afterOccurrences(let count) = end, count < 1 {
            throw ValidationFailure.nonPositiveOccurrenceCount(count)
        }
    }

    /// Plain-language summary, used in confirmations so the user sees exactly
    /// what SARA understood before a repeating series is created.
    public var summary: String {
        let cadence: String
        switch frequency {
        case .daily:
            cadence = interval == 1 ? "every day" : "every \(interval) days"
        case .weekly:
            let days = weekdays.isEmpty ? "" : " on \(Self.list(weekdays.map(Self.name)))"
            if weekdays == Weekday.weekdays, interval == 1 {
                cadence = "every weekday"
            } else {
                cadence = (interval == 1 ? "every week" : "every \(interval) weeks") + days
            }
        case .monthly:
            if let weekNumber, let weekday = weekdays.first {
                cadence = "the \(Self.ordinalName(weekNumber)) \(Self.name(weekday)) of "
                    + (interval == 1 ? "every month" : "every \(interval) months")
            } else {
                cadence = interval == 1 ? "every month" : "every \(interval) months"
            }
        case .yearly:
            cadence = interval == 1 ? "every year" : "every \(interval) years"
        }

        switch end {
        case .never: return cadence
        case .afterOccurrences(let count): return "\(cadence), \(count) times"
        case .onDate: return "\(cadence), until a set date"
        }
    }

    private static func name(_ weekday: Weekday) -> String {
        switch weekday {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    private static func ordinalName(_ value: Int) -> String {
        switch value {
        case 1: "first"
        case 2: "second"
        case 3: "third"
        case 4: "fourth"
        case 5: "fifth"
        case -1: "last"
        default: "\(value)th"
        }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and \(items[items.count - 1])"
        }
    }
}
