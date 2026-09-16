import Foundation
import Testing
@testable import SARACore

/// All fixtures are anchored to Wednesday 16 September 2026, 10:00 UTC.
@Suite("TemporalEngine")
struct TemporalEngineTests {
    private let wednesday10am = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)
    private let wednesdayMidnight = Date(timeIntervalSince1970: 1_789_516_800)

    private func makeEngine(
        now: Date? = nil,
        preferences: TemporalPreferences = .default
    ) -> TemporalEngine {
        TemporalEngine(
            dateProvider: FixedDateProvider(now: now ?? wednesday10am),
            preferences: preferences
        )
    }

    private func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Relative days

    @Test("Today, tomorrow and yesterday resolve to start of day")
    func relativeDays() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolveDay(.today)) == "2026-09-16 00:00")
        #expect(iso(try engine.resolveDay(.tomorrow)) == "2026-09-17 00:00")
        #expect(iso(try engine.resolveDay(.yesterday)) == "2026-09-15 00:00")
        #expect(iso(try engine.resolveDay(.daysFromToday(10))) == "2026-09-26 00:00")
        #expect(iso(try engine.resolveDay(.weeksFromToday(2))) == "2026-09-30 00:00")
    }

    @Test("A clock time is applied to the resolved day")
    func clockTime() throws {
        let engine = makeEngine()
        let resolved = try engine.resolve(
            DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0))
        )
        #expect(iso(resolved.date) == "2026-09-17 16:00")
        #expect(resolved.timeWasSpecified)
    }

    @Test("Day parts use the configured hours")
    func dayParts() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolve(DateTimeSpec(day: .today, time: .part(.afternoon))).date) == "2026-09-16 14:00")
        #expect(iso(try engine.resolve(DateTimeSpec(day: .today, time: .part(.night))).date) == "2026-09-16 21:00")
        #expect(iso(try engine.resolve(DateTimeSpec(day: .today, time: .part(.noon))).date) == "2026-09-16 12:00")

        let custom = makeEngine(preferences: TemporalPreferences(eveningHour: 18))
        #expect(iso(try custom.resolve(DateTimeSpec(day: .today, time: .part(.evening))).date) == "2026-09-16 18:00")
    }

    @Test("\"In two hours\" is measured from now and may cross midnight")
    func offsetFromNow() throws {
        let engine = makeEngine()
        let soon = try engine.resolve(DateTimeSpec(day: .today, time: .offsetFromNow(seconds: 7200)))
        #expect(iso(soon.date) == "2026-09-16 12:00")

        let lateEngine = makeEngine(now: Date(timeIntervalSince1970: 1_789_516_800 + 82_800))
        let crossing = try lateEngine.resolve(DateTimeSpec(day: .today, time: .offsetFromNow(seconds: 7200)))
        #expect(iso(crossing.date) == "2026-09-17 01:00")
    }

    // MARK: - Weekdays

    @Test("An upcoming weekday is the soonest one, today included")
    func upcomingWeekday() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolveDay(.weekday(.friday, .upcoming))) == "2026-09-18 00:00")
        #expect(iso(try engine.resolveDay(.weekday(.wednesday, .upcoming))) == "2026-09-16 00:00")
        #expect(iso(try engine.resolveDay(.weekday(.monday, .upcoming))) == "2026-09-21 00:00")
    }

    @Test("\"Next Friday\" is treated as ambiguous rather than guessed")
    func nextWeekdayIsAmbiguous() throws {
        let engine = makeEngine()

        #expect(throws: TemporalError.self) {
            try engine.resolveDay(.weekday(.friday, .next))
        }

        do {
            _ = try engine.resolveDay(.weekday(.friday, .next))
            Issue.record("Expected an ambiguity error")
        } catch let error as TemporalError {
            guard case .ambiguous(let question, let candidates) = error else {
                Issue.record("Expected .ambiguous, got \(error)")
                return
            }
            #expect(candidates.count == 2)
            #expect(iso(candidates[0]) == "2026-09-18 00:00")
            #expect(iso(candidates[1]) == "2026-09-25 00:00")
            #expect(question.contains("September 18"))
            #expect(question.contains("September 25"))
        }
    }

    @Test("\"Next Monday\" is unambiguous mid-week and needs no question")
    func nextWeekdayUnambiguous() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolveDay(.weekday(.monday, .next))) == "2026-09-21 00:00")
    }

    @Test("\"Last Friday\" looks backwards")
    func previousWeekday() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolveDay(.weekday(.friday, .previous))) == "2026-09-11 00:00")
        #expect(iso(try engine.resolveDay(.weekday(.wednesday, .previous))) == "2026-09-09 00:00")
    }

    @Test("\"This Friday\" stays inside the current week")
    func thisWeekWeekday() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolveDay(.weekday(.friday, .thisWeek))) == "2026-09-18 00:00")
        #expect(iso(try engine.resolveDay(.weekday(.monday, .thisWeek))) == "2026-09-14 00:00")
    }

    // MARK: - Explicit dates

    @Test("A stated date without a year picks the next occurrence")
    func explicitWithoutYear() throws {
        let engine = makeEngine()
        #expect(iso(try engine.resolveDay(.explicit(year: nil, month: 12, day: 25))) == "2026-12-25 00:00")
        #expect(iso(try engine.resolveDay(.explicit(year: nil, month: 1, day: 5))) == "2027-01-05 00:00")
        #expect(iso(try engine.resolveDay(.explicit(year: 2027, month: 3, day: 1))) == "2027-03-01 00:00")
    }

    @Test("Impossible dates and times are rejected, not rolled over")
    func impossibleValues() {
        let engine = makeEngine()

        #expect(throws: TemporalError.impossibleDate("2/31 doesn't exist in 2027")) {
            try engine.resolveDay(.explicit(year: 2027, month: 2, day: 31))
        }
        #expect(throws: TemporalError.self) {
            try engine.resolveDay(.explicit(year: 2026, month: 13, day: 1))
        }
        #expect(throws: TemporalError.self) {
            try engine.resolve(DateTimeSpec(day: .today, time: .clock(hour: 25, minute: 0)))
        }
        #expect(throws: TemporalError.self) {
            try engine.resolve(DateTimeSpec(day: .today, time: .clock(hour: 9, minute: 61)))
        }
    }

    // MARK: - Missing time

    @Test("A missing time is an error unless the caller supplies a default")
    func missingTime() throws {
        let engine = makeEngine()

        #expect(throws: TemporalError.timeRequired) {
            try engine.resolve(DateTimeSpec(day: .tomorrow, time: .unspecified))
        }

        let defaulted = try engine.resolve(
            DateTimeSpec(day: .tomorrow, time: .unspecified),
            defaultTime: (hour: 9, minute: 0)
        )
        #expect(iso(defaulted.date) == "2026-09-17 09:00")
        #expect(!defaulted.timeWasSpecified)
    }

    // MARK: - Intervals

    @Test("A day interval spans exactly one day")
    func dayInterval() throws {
        let engine = makeEngine()
        let interval = try engine.dayInterval(for: .tomorrow)
        #expect(iso(interval.start) == "2026-09-17 00:00")
        #expect(iso(interval.end) == "2026-09-18 00:00")
        #expect(interval.duration == 86_400)
    }

    // MARK: - Time zones

    @Test("Resolution follows the user's time zone, not UTC")
    func timeZoneAware() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        tokyo.locale = Locale(identifier: "en_US_POSIX")

        let engine = TemporalEngine(
            dateProvider: FixedDateProvider(now: wednesdayMidnight, calendar: tokyo)
        )
        // 2026-09-16 00:00 UTC is 09:00 the same day in Tokyo, so "today at
        // 16:00" is 07:00 UTC.
        let resolved = try engine.resolve(DateTimeSpec(day: .today, time: .clock(hour: 16, minute: 0)))
        #expect(resolved.date == Date(timeIntervalSince1970: 1_789_516_800 + 25_200))
    }
}
