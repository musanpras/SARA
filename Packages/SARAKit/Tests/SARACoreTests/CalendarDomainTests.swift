import Foundation
import Testing
@testable import SARACore

@Suite("Calendar domain")
struct CalendarDomainTests {
    private let base = Date(timeIntervalSince1970: 1_758_000_000)

    private func event(
        _ title: String,
        offsetMinutes: Int,
        durationMinutes: Int
    ) -> CalendarEvent {
        let start = base.addingTimeInterval(Double(offsetMinutes) * 60)
        return CalendarEvent(
            id: EventIdentifier(title),
            title: title,
            start: start,
            end: start.addingTimeInterval(Double(durationMinutes) * 60),
            calendarID: CalendarIdentifier("cal"),
            calendarTitle: "Personal"
        )
    }

    @Test("Overlapping events are detected")
    func overlapDetected() {
        let meeting = event("Meeting", offsetMinutes: 0, durationMinutes: 60)
        let gym = event("Gym", offsetMinutes: 30, durationMinutes: 60)

        #expect(meeting.overlaps(gym))
        #expect(gym.overlaps(meeting))
    }

    @Test("Back-to-back events do not conflict")
    func touchingEdgesAreNotConflicts() {
        let first = event("Meeting", offsetMinutes: 0, durationMinutes: 60)
        let second = event("Gym", offsetMinutes: 60, durationMinutes: 60)

        #expect(!first.overlaps(second))
        #expect(!second.overlaps(first))
    }

    @Test("An event fully inside another overlaps it")
    func containmentOverlaps() {
        let long = event("Workshop", offsetMinutes: 0, durationMinutes: 240)
        let short = event("Call", offsetMinutes: 60, durationMinutes: 15)

        #expect(long.overlaps(short))
        #expect(short.overlaps(long))
    }

    @Test("Alert offsets are always at or before the start")
    func alertOffsetsClampToPast() {
        #expect(AlertOffset(secondsBeforeStart: 600).secondsBeforeStart == 0)
        #expect(AlertOffset.minutes(30).secondsBeforeStart == -1800)
        #expect(AlertOffset.minutes(30).minutesBefore == 30)
        #expect(AlertOffset.atTimeOfEvent.minutesBefore == 0)
    }

    @Test("An end before the start yields zero duration rather than a negative one")
    func durationNeverNegative() {
        let inverted = CalendarEvent(
            id: EventIdentifier("x"),
            title: "Broken",
            start: base,
            end: base.addingTimeInterval(-3600),
            calendarID: CalendarIdentifier("cal"),
            calendarTitle: "Personal"
        )
        #expect(inverted.duration == 0)
    }

    @Test("Empty changes are recognised so no pointless write is attempted")
    func emptyChanges() {
        #expect(CalendarEventChanges().isEmpty)
        #expect(!CalendarEventChanges(title: "Gym").isEmpty)
        #expect(ReminderChanges().isEmpty)
        #expect(!ReminderChanges(clearDueDate: true).isEmpty)
    }

    @Test("Calendars sharing a title are distinguished by source")
    func qualifiedTitle() {
        let calendar = CalendarDescriptor(
            id: CalendarIdentifier("a"),
            title: "Work",
            sourceTitle: "Exchange",
            allowsModification: true,
            isDefaultForNewEvents: false
        )
        #expect(calendar.qualifiedTitle == "Work (Exchange)")
    }
}
