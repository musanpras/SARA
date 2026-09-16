import Foundation
import Testing
@testable import SARACore

@Suite("LocalCommandInterpreter")
struct LocalCommandInterpreterTests {
    private let interpreter = LocalCommandInterpreter()
    private let now = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)

    private func parse(_ text: String) -> ActionPlan? {
        let request = UserRequest(text: text, source: .text, timestamp: now)
        guard case .plan(let plan)? = interpreter.parse(request) else { return nil }
        return plan
    }

    private func firstPayload(_ text: String) -> ActionPayload? {
        parse(text)?.actions.first?.payload
    }

    // MARK: - Create events

    @Test("A complete scheduling command becomes one create action")
    func scheduleWithEverything() throws {
        guard case .calendarCreate(let parameters)? = firstPayload("Schedule gym tomorrow at 4 PM for one hour") else {
            Issue.record("Expected calendar.create")
            return
        }
        #expect(parameters.title == "gym")
        #expect(parameters.when?.day == .tomorrow)
        #expect(parameters.when?.time == .clock(hour: 16, minute: 0))
        #expect(parameters.durationMinutes == 60)
    }

    @Test("Titles keep their original capitalisation")
    func titleCasingPreserved() throws {
        guard case .calendarCreate(let parameters)? = firstPayload("Schedule Team Sync tomorrow at 10 AM") else {
            Issue.record("Expected calendar.create")
            return
        }
        #expect(parameters.title == "Team Sync")
    }

    @Test("Time formats are understood", arguments: [
        ("Schedule standup tomorrow at 9", 9, 0),
        ("Schedule standup tomorrow at 9 am", 9, 0),
        ("Schedule standup tomorrow at 9:30", 9, 30),
        ("Schedule standup tomorrow at 4:45 pm", 16, 45),
        ("Schedule standup tomorrow at 12 am", 0, 0),
        ("Schedule standup tomorrow at 12 pm", 12, 0),
    ])
    func timeFormats(text: String, hour: Int, minute: Int) throws {
        guard case .calendarCreate(let parameters)? = firstPayload(text) else {
            Issue.record("Expected calendar.create for \(text)")
            return
        }
        #expect(parameters.when?.time == .clock(hour: hour, minute: minute))
    }

    @Test("Durations are understood", arguments: [
        ("Schedule gym tomorrow at 4 pm for 30 minutes", 30),
        ("Schedule gym tomorrow at 4 pm for two hours", 120),
        ("Schedule gym tomorrow at 4 pm for half an hour", 30),
        ("Schedule gym tomorrow at 4 pm for an hour", 60),
    ])
    func durations(text: String, minutes: Int) throws {
        guard case .calendarCreate(let parameters)? = firstPayload(text) else {
            Issue.record("Expected calendar.create for \(text)")
            return
        }
        #expect(parameters.durationMinutes == minutes)
    }

    @Test("A missing time is left unspecified rather than filled in")
    func missingTimeStaysMissing() throws {
        guard case .calendarCreate(let parameters)? = firstPayload("Schedule dentist tomorrow") else {
            Issue.record("Expected calendar.create")
            return
        }
        #expect(parameters.when?.day == .tomorrow)
        #expect(parameters.when?.time == .unspecified)
    }

    @Test("Recurrence phrases are recognised", arguments: [
        ("Schedule standup every weekday at 9 am", RecurrenceRule.everyWeekday),
        ("Schedule yoga every Monday at 7 pm", RecurrenceRule.every(.monday)),
        ("Schedule review every two weeks at 3 pm", RecurrenceRule.everyNWeeks(2)),
        ("Schedule planning the first Monday of every month at 10 am",
         RecurrenceRule.monthly(ordinal: 1, weekday: .monday)),
    ])
    func recurrence(text: String, expected: RecurrenceRule) throws {
        guard case .calendarCreate(let parameters)? = firstPayload(text) else {
            Issue.record("Expected calendar.create for \(text)")
            return
        }
        #expect(parameters.recurrence == expected)
    }

    @Test("An explicitly named calendar is extracted and kept out of the title")
    func explicitCalendar() throws {
        guard case .calendarCreate(let parameters)? =
            firstPayload("Schedule standup on my Work calendar tomorrow at 9 AM")
        else {
            Issue.record("Expected calendar.create")
            return
        }
        #expect(parameters.calendarName == "Work")
        #expect(parameters.title == "standup")
    }

    @Test("Two-word calendar names survive", arguments: [
        ("Schedule review on my Work Travel calendar tomorrow at 9 AM", "Work Travel"),
        ("Schedule dinner in the Family calendar tomorrow at 7 PM", "Family"),
    ])
    func calendarNameForms(text: String, expected: String) throws {
        guard case .calendarCreate(let parameters)? = firstPayload(text) else {
            Issue.record("Expected calendar.create for \(text)")
            return
        }
        #expect(parameters.calendarName == expected)
    }

    @Test("A reminders list can be named explicitly")
    func explicitList() throws {
        guard case .reminderCreate(let parameters)? =
            firstPayload("Remind me to buy milk in my Groceries list tomorrow at 9 AM")
        else {
            Issue.record("Expected reminder.create")
            return
        }
        #expect(parameters.listName == "Groceries")
        #expect(parameters.title == "buy milk")
    }

    @Test("A bare preposition is not mistaken for a calendar name")
    func noFalseCalendarMatch() throws {
        guard case .calendarCreate(let parameters)? = firstPayload("Schedule lunch with Sam tomorrow at 1 PM")
        else {
            Issue.record("Expected calendar.create")
            return
        }
        #expect(parameters.calendarName == nil)
        #expect(parameters.title == "lunch with Sam")
    }

    // MARK: - Create reminders

    @Test("\"Remind me to X tomorrow at 8 PM\" becomes a reminder")
    func reminderWithDueDate() throws {
        guard case .reminderCreate(let parameters)? = firstPayload("Remind me to submit my assignment tomorrow at 8 PM") else {
            Issue.record("Expected reminder.create")
            return
        }
        #expect(parameters.title == "submit my assignment")
        #expect(parameters.due?.day == .tomorrow)
        #expect(parameters.due?.time == .clock(hour: 20, minute: 0))
    }

    @Test("A reminder with no date at all has no due spec")
    func reminderWithoutDate() throws {
        guard case .reminderCreate(let parameters)? = firstPayload("Remind me to call the bank") else {
            Issue.record("Expected reminder.create")
            return
        }
        #expect(parameters.title == "call the bank")
        #expect(parameters.due == nil)
    }

    // MARK: - Search

    @Test("Calendar questions become calendar searches", arguments: [
        "What's on my calendar tomorrow?",
        "What is my schedule tomorrow",
        "Show me my events tomorrow",
    ])
    func calendarSearches(text: String) throws {
        guard case .calendarSearch(let parameters)? = firstPayload(text) else {
            Issue.record("Expected calendar.search for \(text)")
            return
        }
        #expect(parameters.query.day == .tomorrow)
    }

    @Test("\"What do I need to do tomorrow?\" searches both sources")
    func unifiedSearch() throws {
        let plan = try #require(parse("What do I need to do tomorrow?"))
        #expect(plan.actions.map(\.type) == [.calendarSearch, .reminderSearch])
        #expect(plan.actions.allSatisfy { $0.payload.target?.day == .tomorrow })
    }

    @Test("A calendar question with no day defaults to today")
    func searchDefaultsToToday() throws {
        guard case .calendarSearch(let parameters)? = firstPayload("What's on my calendar?") else {
            Issue.record("Expected calendar.search")
            return
        }
        #expect(parameters.query.day == .today)
    }

    // MARK: - Update

    @Test("\"Move gym tomorrow to 6 PM\" targets the event and changes the time")
    func moveEvent() throws {
        guard case .calendarUpdate(let parameters)? = firstPayload("Move gym tomorrow to 6 PM") else {
            Issue.record("Expected calendar.update")
            return
        }
        #expect(parameters.target.titleContains == "gym")
        #expect(parameters.target.day == .tomorrow)
        #expect(parameters.changes.when?.time == .clock(hour: 18, minute: 0))
        // No new day was stated, so the event keeps the one it is on.
        #expect(parameters.changes.when?.day == nil)
    }

    @Test("A stated old time describes the target, not the change")
    func moveFromTo() throws {
        guard case .calendarUpdate(let parameters)? = firstPayload("Move my gym tomorrow from 2 PM to 6 PM") else {
            Issue.record("Expected calendar.update")
            return
        }
        #expect(parameters.target.titleContains == "gym")
        #expect(parameters.target.time == .clock(hour: 14, minute: 0))
        #expect(parameters.changes.when?.time == .clock(hour: 18, minute: 0))
    }

    // MARK: - Delete

    @Test("Deletion phrasings are recognised", arguments: [
        "Delete my meeting tomorrow",
        "Cancel my meeting tomorrow",
        "Remove my meeting tomorrow",
    ])
    func deletePhrasings(text: String) throws {
        guard case .calendarDelete(let parameters)? = firstPayload(text) else {
            Issue.record("Expected calendar.delete for \(text)")
            return
        }
        #expect(parameters.target.titleContains == "meeting")
        #expect(parameters.target.day == .tomorrow)
    }

    @Test("\"Delete the reminder to call John\" targets reminders")
    func deleteReminder() throws {
        guard case .reminderDelete(let parameters)? = firstPayload("Delete the reminder to call John") else {
            Issue.record("Expected reminder.delete")
            return
        }
        #expect(parameters.target.scope == .reminders)
        // "reminder" names the kind of record, not the record; leaving it in
        // the title searches for a reminder called "reminder to call John".
        #expect(parameters.target.titleContains == "call John")
    }

    @Test("A kind marker is stripped only when a name follows it", arguments: [
        ("Delete the reminder to call John", "call John"),
        ("Delete the event called Standup", "Standup"),
        ("Cancel my meeting about budgets", "budgets"),
        // Nothing follows the marker, so it is the title.
        ("Delete my meeting tomorrow", "meeting"),
        ("Delete Gym tomorrow", "Gym"),
    ])
    func kindMarkerStripping(text: String, expected: String) throws {
        guard let target = firstPayload(text)?.target else {
            Issue.record("Expected a delete action for \(text)")
            return
        }
        #expect(target.titleContains == expected)
    }

    // MARK: - Multi-action

    @Test("\"...and remind me 30 minutes before\" becomes an alert on the event")
    func trailingAlert() throws {
        let plan = try #require(parse("Schedule gym tomorrow at 4 PM and remind me 30 minutes before"))
        #expect(plan.actions.count == 1)

        guard case .calendarCreate(let parameters) = plan.actions[0].payload else {
            Issue.record("Expected calendar.create")
            return
        }
        #expect(parameters.title == "gym")
        #expect(parameters.alertMinutesBefore == [30])
    }

    @Test("\"...and remind me to X\" becomes a second, dependent action")
    func dependentReminder() throws {
        let plan = try #require(parse("Schedule gym tomorrow at 4 PM and remind me to bring my kit"))
        #expect(plan.actions.count == 2)
        #expect(plan.actions[0].type == .calendarCreate)
        #expect(plan.actions[1].type == .reminderCreate)
        #expect(plan.actions[1].dependsOn == ["primary"])
    }

    // MARK: - Undo

    @Test("Undo phrasings are recognised", arguments: ["Undo that", "undo", "Take that back"])
    func undoPhrasings(text: String) throws {
        let plan = try #require(parse(text))
        #expect(plan.actions.map(\.type) == [.undo])
    }

    // MARK: - Declining

    @Test("Phrasing it cannot handle is declined rather than guessed at", arguments: [
        "What's the weather like tomorrow?",
        "Find me a two hour gap next week between my meetings",
        "Tell me a joke",
        "",
    ])
    func declinesUnknownPhrasing(text: String) {
        let request = UserRequest(text: text, source: .text, timestamp: now)
        #expect(interpreter.parse(request) == nil)
    }
}
