import Foundation
import Testing
@testable import SARACore

@Suite("RecurrenceRule")
struct RecurrenceRuleTests {
    @Test("Common patterns build the expected structure")
    func commonPatterns() throws {
        #expect(RecurrenceRule.every(.monday).weekdays == [.monday])
        #expect(RecurrenceRule.everyWeekday.weekdays == [.monday, .tuesday, .wednesday, .thursday, .friday])
        #expect(RecurrenceRule.everyNWeeks(2, on: [.monday]).interval == 2)

        let firstMonday = RecurrenceRule.monthly(ordinal: 1, weekday: .monday)
        #expect(firstMonday.frequency == .monthly)
        #expect(firstMonday.weekNumber == 1)

        for rule in [RecurrenceRule.everyDay, .every(.monday), .everyWeekday,
                     .everyNWeeks(2, on: [.monday]), firstMonday] {
            try rule.validate()
        }
    }

    @Test("Summaries read as plain language")
    func summaries() {
        #expect(RecurrenceRule.everyDay.summary == "every day")
        #expect(RecurrenceRule.every(.monday).summary == "every week on Monday")
        #expect(RecurrenceRule.everyWeekday.summary == "every weekday")
        #expect(RecurrenceRule.everyNWeeks(2).summary == "every 2 weeks")
        #expect(RecurrenceRule.monthly(ordinal: 1, weekday: .monday).summary == "the first Monday of every month")
        #expect(RecurrenceRule.monthly(ordinal: -1, weekday: .friday).summary == "the last Friday of every month")

        var limited = RecurrenceRule.everyDay
        limited.end = .afterOccurrences(5)
        #expect(limited.summary == "every day, 5 times")
    }

    @Test("Weekday lists are joined readably")
    func weekdayLists() {
        let two = RecurrenceRule(frequency: .weekly, weekdays: [.monday, .thursday])
        #expect(two.summary == "every week on Monday and Thursday")

        let three = RecurrenceRule(frequency: .weekly, weekdays: [.monday, .wednesday, .friday])
        #expect(three.summary == "every week on Monday, Wednesday and Friday")
    }

    @Test("Invalid rules are rejected before they reach EventKit", arguments: [
        RecurrenceRule(frequency: .daily, interval: 0),
        RecurrenceRule(frequency: .monthly, weekdays: [.monday], weekNumber: 0),
        RecurrenceRule(frequency: .monthly, weekdays: [.monday], weekNumber: 9),
        RecurrenceRule(frequency: .monthly, weekNumber: 1),
        RecurrenceRule(frequency: .weekly, weekdays: [.monday], weekNumber: 1),
        RecurrenceRule(frequency: .monthly, daysOfMonth: [0]),
        RecurrenceRule(frequency: .monthly, daysOfMonth: [40]),
        RecurrenceRule(frequency: .daily, end: .afterOccurrences(0)),
    ])
    func invalidRules(rule: RecurrenceRule) {
        #expect(throws: RecurrenceRule.ValidationFailure.self) {
            try rule.validate()
        }
    }

    @Test("Rules survive a JSON round trip, since the AI layer emits them as JSON")
    func codableRoundTrip() throws {
        let original = RecurrenceRule.monthly(ordinal: -1, weekday: .friday)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: data)
        #expect(decoded == original)
    }
}
