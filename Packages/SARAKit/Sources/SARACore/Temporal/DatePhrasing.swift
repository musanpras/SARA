import Foundation

/// Turns dates into the phrases SARA speaks: "tomorrow at 4 PM", "Friday at
/// 3 PM", "on 3 October".
///
/// Kept deterministic and locale-aware rather than delegated to a model, so the
/// date the user hears is always the date SARA resolved.
public struct DatePhrasing: Sendable {
    private let calendar: Calendar
    private let locale: Locale

    public init(calendar: Calendar) {
        self.calendar = calendar
        self.locale = calendar.locale ?? .autoupdatingCurrent
    }

    /// A day relative to `now`: "today", "tomorrow", "Friday", "on 3 October".
    public func day(_ date: Date, relativeTo now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6: return weekdayName(target)
        case -6 ... -2: return "last \(weekdayName(target))"
        default: return "on \(mediumDate(target))"
        }
    }

    /// A clock time in the user's locale: "4 PM", "16:00".
    public func time(_ date: Date) -> String {
        let formatter = makeFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        var text = formatter.string(from: date)
        // "4:00 PM" reads better as "4 PM" when spoken. The minute separator is
        // locale-dependent — a colon in en_US, a dot in id_ID — so both are
        // stripped. Non-zero minutes ("14.30") are left alone.
        text = text.replacingOccurrences(of: ":00", with: "")
        text = text.replacingOccurrences(of: ".00", with: "")
        // Modern formatters insert a narrow no-break space before AM/PM. It is
        // invisible but breaks string comparison, so it is normalised here —
        // these strings are matched and searched elsewhere in the pipeline.
        return text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The full phrase: "tomorrow at 4 PM", or just the day when there is no
    /// meaningful time.
    public func dayAndTime(_ date: Date, relativeTo now: Date, includeTime: Bool = true) -> String {
        let dayText = day(date, relativeTo: now)
        guard includeTime else { return dayText }
        return "\(dayText) at \(time(date))"
    }

    /// A one-line description of an event, as used in disambiguation lists.
    public func describe(_ event: CalendarEvent, relativeTo now: Date) -> String {
        let when = dayAndTime(event.start, relativeTo: now, includeTime: !event.isAllDay)
        return "\(event.title) \(when)"
    }

    public func describe(_ reminder: Reminder, relativeTo now: Date) -> String {
        guard let due = reminder.dueDate else { return reminder.title }
        let when = dayAndTime(due, relativeTo: now, includeTime: reminder.hasTimeComponent)
        return "\(reminder.title) \(when)"
    }

    private func weekdayName(_ date: Date) -> String {
        let formatter = makeFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date)
    }

    private func mediumDate(_ date: Date) -> String {
        let formatter = makeFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter.string(from: date)
    }

    private func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        return formatter
    }
}
