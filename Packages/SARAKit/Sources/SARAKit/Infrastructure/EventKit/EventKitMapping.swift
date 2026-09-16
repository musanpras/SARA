import EventKit
import SARACore

/// Translations between EventKit and SARA's domain types.
///
/// This file is the only place EventKit classes are read. Everything above it
/// works with value types, which keeps the domain testable without a store.
enum EventKitMapping {
    static func permissionStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    static func descriptor(_ calendar: EKCalendar, defaultCalendarID: String?) -> CalendarDescriptor {
        CalendarDescriptor(
            id: CalendarIdentifier(calendar.calendarIdentifier),
            title: calendar.title,
            sourceTitle: calendar.source?.title ?? "",
            allowsModification: calendar.allowsContentModifications,
            isDefaultForNewEvents: calendar.calendarIdentifier == defaultCalendarID
        )
    }

    static func alerts(_ alarms: [EKAlarm]?) -> [AlertOffset] {
        // Absolute alarms are dropped rather than guessed at: SARA only models
        // relative alerts, and inventing an offset could misreport the event.
        (alarms ?? [])
            .filter { $0.absoluteDate == nil }
            .map { AlertOffset(secondsBeforeStart: $0.relativeOffset) }
    }

    static func event(_ event: EKEvent) -> CalendarEvent? {
        guard let identifier = event.eventIdentifier,
              let start = event.startDate,
              let end = event.endDate
        else { return nil }

        return CalendarEvent(
            id: EventIdentifier(identifier),
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            calendarID: CalendarIdentifier(event.calendar?.calendarIdentifier ?? ""),
            calendarTitle: event.calendar?.title ?? "",
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes?.isEmpty == false ? event.notes : nil,
            alerts: alerts(event.alarms),
            isRecurring: event.hasRecurrenceRules
        )
    }

    static func span(_ span: EventSpan) -> EKSpan {
        switch span {
        case .thisEvent: .thisEvent
        case .futureEvents: .futureEvents
        }
    }

    static func alarms(for alerts: [AlertOffset]) -> [EKAlarm] {
        alerts.map { EKAlarm(relativeOffset: $0.secondsBeforeStart) }
    }

    static func recurrenceRule(_ rule: RecurrenceRule) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }

        // EventKit carries the ordinal ("first Monday") on the day itself
        // rather than as a separate set position.
        let days: [EKRecurrenceDayOfWeek]? = rule.weekdays.isEmpty ? nil : rule.weekdays.map { weekday in
            if let weekNumber = rule.weekNumber {
                EKRecurrenceDayOfWeek(EKWeekday(rawValue: weekday.calendarValue) ?? .monday, weekNumber: weekNumber)
            } else {
                EKRecurrenceDayOfWeek(EKWeekday(rawValue: weekday.calendarValue) ?? .monday)
            }
        }

        let end: EKRecurrenceEnd? = switch rule.end {
        case .never: nil
        case .afterOccurrences(let count): EKRecurrenceEnd(occurrenceCount: count)
        case .onDate(let date): EKRecurrenceEnd(end: date)
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: rule.interval,
            daysOfTheWeek: days,
            daysOfTheMonth: rule.daysOfMonth.isEmpty ? nil : rule.daysOfMonth.map(NSNumber.init(value:)),
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }
}
