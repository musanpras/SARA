import Foundation
import Testing
import SARACore
import SARATesting

/// Anchored to Wednesday 16 September 2026, 10:00 UTC.
@Suite("PlanValidator")
struct PlanValidatorTests {
    private let now = Date(timeIntervalSince1970: 1_789_516_800 + 36_000)
    private let requestID = UUID()

    private func makeValidator(
        calendar: InMemoryCalendarService = InMemoryCalendarService(),
        reminders: InMemoryReminderService = InMemoryReminderService(),
        preferences: SARAPreferences = .default
    ) -> PlanValidator {
        PlanValidator(
            calendarService: calendar,
            reminderService: reminders,
            temporal: TemporalEngine(
                dateProvider: FixedDateProvider(now: now),
                preferences: preferences.temporal
            ),
            preferences: preferences
        )
    }

    private func plan(
        _ payload: ActionPayload,
        confirmation: ConfirmationState = .notRequired
    ) -> ActionPlan {
        ActionPlan(
            requestID: requestID,
            actions: [PlannedAction(id: "a1", payload: payload)],
            confirmationState: confirmation
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

    private func seededEvent(
        _ title: String,
        day: String,
        hour: Int,
        durationMinutes: Int = 60,
        id: String? = nil
    ) -> CalendarEvent {
        let formatter = DateFormatter()
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: day)!.addingTimeInterval(Double(hour) * 3600)
        return CalendarEvent(
            id: EventIdentifier(id ?? "\(title)-\(day)-\(hour)"),
            title: title,
            start: start,
            end: start.addingTimeInterval(Double(durationMinutes) * 60),
            calendarID: CalendarDescriptor.personal.id,
            calendarTitle: "Personal"
        )
    }

    // MARK: - Create: missing information

    @Test("A missing title is asked about, not invented")
    func missingTitle() async {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "  ",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0))
            ))),
            context: ValidationContext()
        )

        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.subject == .eventTitle)
        #expect(request.question == "What should I call the event?")
    }

    @Test("A missing date is asked about")
    func missingDate() async {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(title: "Gym"))),
            context: ValidationContext()
        )
        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.subject == .eventDate)
        #expect(request.question == "When is it?")
    }

    @Test("A missing event time is asked about rather than defaulted")
    func missingTime() async {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Gym",
                when: DateTimeSpec(day: .tomorrow, time: .unspecified)
            ))),
            context: ValidationContext()
        )
        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.subject == .eventTime)
    }

    @Test("Only one question is asked at a time")
    func oneQuestionAtATime() async {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(title: ""))),
            context: ValidationContext()
        )
        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        // Title and date are both missing; SARA asks for the title only.
        #expect(request.subject == .eventTitle)
    }

    // MARK: - Create: happy path

    @Test("A complete create needs no confirmation and resolves the dates")
    func completeCreate() async throws {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Gym",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0)),
                durationMinutes: 60
            ))),
            context: ValidationContext()
        )

        guard case .ready(let executable) = outcome,
              case .createEvent(let draft) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a ready create, got \(outcome)")
            return
        }
        #expect(draft.title == "Gym")
        #expect(iso(draft.start) == "2026-09-17 16:00")
        #expect(iso(draft.end) == "2026-09-17 17:00")
        #expect(draft.calendarID == CalendarDescriptor.personal.id)
    }

    @Test("A stated duration is honoured and an unstated one uses the default")
    func durationDefaults() async throws {
        let preferences = SARAPreferences(temporal: TemporalPreferences(defaultEventDuration: 1800))
        let outcome = await makeValidator(preferences: preferences).validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Standup",
                when: DateTimeSpec(day: .today, time: .clock(hour: 11, minute: 0))
            ))),
            context: ValidationContext()
        )
        guard case .ready(let executable) = outcome,
              case .createEvent(let draft) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a ready create, got \(outcome)")
            return
        }
        #expect(draft.end.timeIntervalSince(draft.start) == 1800)
    }

    @Test("\"Remind me 30 minutes before\" becomes a relative alert")
    func alertsAreRelative() async throws {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Gym",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0)),
                alertMinutesBefore: [30]
            ))),
            context: ValidationContext()
        )
        guard case .ready(let executable) = outcome,
              case .createEvent(let draft) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a ready create, got \(outcome)")
            return
        }
        #expect(draft.alerts == [AlertOffset.minutes(30)])
    }

    // MARK: - Conflicts

    @Test("A conflicting time is flagged, never silently overlapped")
    func conflictAsksFirst() async {
        let service = InMemoryCalendarService()
        await service.seed([seededEvent("Team Meeting", day: "2026-09-17", hour: 14)])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Gym",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 14, minute: 0))
            ))),
            context: ValidationContext()
        )

        guard case .needsConfirmation(let request, let executable) = outcome else {
            Issue.record("Expected a conflict confirmation, got \(outcome)")
            return
        }
        guard case .conflict(let existing) = request.reason else {
            Issue.record("Expected a conflict reason")
            return
        }
        #expect(existing.map(\.title) == ["Team Meeting"])
        #expect(request.question.contains("Team Meeting"))
        #expect(executable.actions.count == 1)
        #expect(await service.createCount == 0)
    }

    @Test("Back-to-back events are not treated as conflicts")
    func adjacentIsNotConflict() async {
        let service = InMemoryCalendarService()
        await service.seed([seededEvent("Team Meeting", day: "2026-09-17", hour: 13)])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Gym",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 14, minute: 0))
            ))),
            context: ValidationContext()
        )
        guard case .ready = outcome else {
            Issue.record("Expected ready, got \(outcome)")
            return
        }
    }

    @Test("An already-confirmed plan is not asked about again")
    func confirmedPlanProceeds() async {
        let service = InMemoryCalendarService()
        await service.seed([seededEvent("Team Meeting", day: "2026-09-17", hour: 14)])

        let outcome = await makeValidator(calendar: service).validate(
            plan(
                .calendarCreate(CalendarCreateParameters(
                    title: "Gym",
                    when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 14, minute: 0))
                )),
                confirmation: .confirmed
            ),
            context: ValidationContext()
        )
        guard case .ready = outcome else {
            Issue.record("Expected ready, got \(outcome)")
            return
        }
    }

    // MARK: - Calendar selection

    @Test("An unknown calendar name is refused rather than swapped for a default")
    func unknownCalendarRefused() async {
        let outcome = await makeValidator().validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Gym",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0)),
                calendarName: "Fitness"
            ))),
            context: ValidationContext()
        )
        #expect(outcome.rejectionMessage?.contains("Fitness") == true)
    }

    @Test("Two calendars with the same name produce a question, not a coin flip")
    func ambiguousCalendarAsks() async {
        let icloud = CalendarDescriptor(
            id: CalendarIdentifier("home-icloud"), title: "Home",
            sourceTitle: "iCloud", allowsModification: true, isDefaultForNewEvents: true
        )
        let gmail = CalendarDescriptor(
            id: CalendarIdentifier("home-gmail"), title: "Home",
            sourceTitle: "Gmail", allowsModification: true, isDefaultForNewEvents: false
        )
        let service = InMemoryCalendarService(calendars: [icloud, gmail])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarCreate(CalendarCreateParameters(
                title: "Dinner",
                when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 19, minute: 0)),
                calendarName: "Home"
            ))),
            context: ValidationContext()
        )

        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.subject == .whichContainer)
        #expect(request.options.map(\.label) == ["Home (iCloud)", "Home (Gmail)"])
    }

    // MARK: - Delete

    @Test("A delete always requires explicit confirmation")
    func deleteRequiresConfirmation() async {
        let service = InMemoryCalendarService()
        await service.seed([seededEvent("Gym", day: "2026-09-17", hour: 14)])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarDelete(DeleteParameters(
                target: EntityQuery(scope: .calendar, titleContains: "Gym", day: .tomorrow)
            ))),
            context: ValidationContext()
        )

        guard case .needsConfirmation(let request, _) = outcome else {
            Issue.record("Expected a confirmation, got \(outcome)")
            return
        }
        #expect(request.reason == .destructive)
        #expect(request.question.contains("Gym"))
        #expect(request.question.contains("tomorrow"))
        #expect(await service.deleteCount == 0)
    }

    @Test("Several matches produce one question listing them all")
    func ambiguousDeleteAsks() async {
        let service = InMemoryCalendarService()
        await service.seed([
            seededEvent("Team Meeting", day: "2026-09-16", hour: 14, id: "m1"),
            seededEvent("Team Meeting", day: "2026-09-17", hour: 10, id: "m2"),
            seededEvent("Team Meeting", day: "2026-09-18", hour: 15, id: "m3"),
        ])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarDelete(DeleteParameters(
                target: EntityQuery(scope: .calendar, titleContains: "Team Meeting")
            ))),
            context: ValidationContext()
        )

        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.subject == .whichRecord)
        #expect(request.options.count == 3)
        #expect(request.options[0].label == "Team Meeting today at 2 PM")
        #expect(request.options[1].label == "Team Meeting tomorrow at 10 AM")
        #expect(request.options[2].label == "Team Meeting Friday at 3 PM")
    }

    @Test("Deleting something that does not exist reports that plainly")
    func deleteNotFound() async {
        let outcome = await makeValidator().validate(
            plan(.calendarDelete(DeleteParameters(
                target: EntityQuery(scope: .calendar, titleContains: "Gym", day: .tomorrow)
            ))),
            context: ValidationContext()
        )
        #expect(outcome.rejectionMessage?.contains("couldn't find") == true)
    }

    @Test("A delete with nothing identifying the target is refused outright")
    func unconstrainedDeleteRefused() async {
        let outcome = await makeValidator().validate(
            plan(.calendarDelete(DeleteParameters(target: EntityQuery(scope: .calendar)))),
            context: ValidationContext()
        )
        guard case .rejected(.unconstrainedTarget) = outcome else {
            Issue.record("Expected an unconstrained-target rejection, got \(outcome)")
            return
        }
    }

    // MARK: - Update

    @Test("An unambiguous move runs without confirmation and keeps the duration")
    func unambiguousMove() async throws {
        let service = InMemoryCalendarService()
        await service.seed([seededEvent("Gym", day: "2026-09-17", hour: 14, durationMinutes: 90)])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarUpdate(UpdateParameters(
                target: EntityQuery(scope: .calendar, titleContains: "Gym", day: .tomorrow),
                changes: EventChangeSpec(when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 18, minute: 0)))
            ))),
            context: ValidationContext()
        )

        guard case .ready(let executable) = outcome,
              case .updateEvent(let target, let changes, _) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a ready update, got \(outcome)")
            return
        }
        #expect(target.title == "Gym")
        #expect(iso(try #require(changes.start)) == "2026-09-17 18:00")
        #expect(iso(try #require(changes.end)) == "2026-09-17 19:30")
    }

    @Test("An ambiguous update asks which one")
    func ambiguousUpdateAsks() async {
        let service = InMemoryCalendarService()
        await service.seed([
            seededEvent("Gym", day: "2026-09-17", hour: 8, id: "g1"),
            seededEvent("Gym", day: "2026-09-17", hour: 18, id: "g2"),
        ])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarUpdate(UpdateParameters(
                target: EntityQuery(scope: .calendar, titleContains: "Gym", day: .tomorrow),
                changes: EventChangeSpec(title: "Gym session")
            ))),
            context: ValidationContext()
        )
        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.options.count == 2)
    }

    @Test("Moving an event onto another commitment asks first")
    func updateIntoConflictAsks() async {
        let service = InMemoryCalendarService()
        await service.seed([
            seededEvent("Gym", day: "2026-09-17", hour: 14, id: "g1"),
            seededEvent("Dentist", day: "2026-09-17", hour: 18, id: "d1"),
        ])

        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarUpdate(UpdateParameters(
                target: EntityQuery(scope: .calendar, titleContains: "Gym", day: .tomorrow),
                changes: EventChangeSpec(when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 18, minute: 0)))
            ))),
            context: ValidationContext()
        )
        guard case .needsConfirmation(let request, _) = outcome else {
            Issue.record("Expected a conflict confirmation, got \(outcome)")
            return
        }
        #expect(request.question.contains("Dentist"))
    }

    // MARK: - References

    @Test("\"The second one\" resolves against what SARA just listed")
    func ordinalReference() async throws {
        let first = seededEvent("Gym", day: "2026-09-17", hour: 8, id: "g1")
        let second = seededEvent("Gym", day: "2026-09-17", hour: 18, id: "g2")
        let service = InMemoryCalendarService()
        await service.seed([first, second])

        let context = ValidationContext(references: ReferenceContext(presentedEvents: [first, second]))
        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarDelete(DeleteParameters(
                target: EntityQuery(scope: .calendar, reference: .ordinal(2))
            ))),
            context: context
        )

        guard case .needsConfirmation(_, let executable) = outcome,
              case .deleteEvent(let target, _) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a delete confirmation, got \(outcome)")
            return
        }
        #expect(target.id == second.id)
    }

    @Test("An out-of-range ordinal finds nothing rather than the wrong record")
    func outOfRangeOrdinal() async {
        let first = seededEvent("Gym", day: "2026-09-17", hour: 8, id: "g1")
        let service = InMemoryCalendarService()
        await service.seed([first])

        let context = ValidationContext(references: ReferenceContext(presentedEvents: [first]))
        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarDelete(DeleteParameters(
                target: EntityQuery(scope: .calendar, reference: .ordinal(5))
            ))),
            context: context
        )
        #expect(outcome.rejectionMessage?.contains("couldn't find") == true)
    }

    // MARK: - Permissions

    @Test("Denied calendar access is reported, not worked around")
    func deniedCalendarAccess() async {
        let service = InMemoryCalendarService(status: .denied)
        let outcome = await makeValidator(calendar: service).validate(
            plan(.calendarSearch(SearchParameters(query: EntityQuery(scope: .calendar, day: .tomorrow)))),
            context: ValidationContext()
        )
        guard case .rejected(.permission(let error)) = outcome else {
            Issue.record("Expected a permission rejection, got \(outcome)")
            return
        }
        #expect(error.capability == .calendar)
    }

    @Test("Access is requested only when the capability is actually used")
    func progressivePermission() async {
        let calendars = InMemoryCalendarService(status: .notDetermined)
        let reminders = InMemoryReminderService(status: .notDetermined)

        let outcome = await makeValidator(calendar: calendars, reminders: reminders).validate(
            plan(.calendarSearch(SearchParameters(query: EntityQuery(scope: .calendar, day: .tomorrow)))),
            context: ValidationContext()
        )
        guard case .ready = outcome else {
            Issue.record("Expected ready, got \(outcome)")
            return
        }
        #expect(await calendars.authorizationStatus() == .authorized)
        // Reminders were never touched, so they were never prompted for.
        #expect(await reminders.authorizationStatus() == .notDetermined)
    }

    // MARK: - Reminders

    @Test("A reminder with no stated time uses the configured default")
    func reminderDefaultTime() async throws {
        let preferences = SARAPreferences(
            temporal: TemporalPreferences(defaultReminderHour: 8, defaultReminderMinute: 30)
        )
        let outcome = await makeValidator(preferences: preferences).validate(
            plan(.reminderCreate(ReminderCreateParameters(
                title: "Submit assignment",
                due: DateTimeSpec(day: .tomorrow, time: .unspecified)
            ))),
            context: ValidationContext()
        )
        guard case .ready(let executable) = outcome,
              case .createReminder(let draft) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a ready reminder, got \(outcome)")
            return
        }
        #expect(iso(try #require(draft.dueDate)) == "2026-09-17 08:30")
    }

    @Test("A reminder without a title is asked about")
    func reminderMissingTitle() async {
        let outcome = await makeValidator().validate(
            plan(.reminderCreate(ReminderCreateParameters(title: ""))),
            context: ValidationContext()
        )
        guard case .needsClarification(let request) = outcome else {
            Issue.record("Expected a clarification, got \(outcome)")
            return
        }
        #expect(request.subject == .reminderTitle)
    }

    // MARK: - Undo and multi-action

    @Test("Undo with nothing to reverse is refused")
    func undoWithNoHistory() async {
        let outcome = await makeValidator().validate(
            plan(.undo(UndoParameters())),
            context: ValidationContext(hasUndoableAction: false)
        )
        guard case .rejected(.nothingToUndo) = outcome else {
            Issue.record("Expected nothingToUndo, got \(outcome)")
            return
        }
    }

    @Test("A dependent two-action plan is ordered into waves")
    func multiActionWaves() async throws {
        let actions = [
            PlannedAction(
                id: "event",
                payload: .calendarCreate(CalendarCreateParameters(
                    title: "Gym",
                    when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0))
                ))
            ),
            PlannedAction(
                id: "reminder",
                payload: .reminderCreate(ReminderCreateParameters(
                    title: "Leave for the gym",
                    due: DateTimeSpec(day: .tomorrow, time: .clock(hour: 15, minute: 30))
                )),
                dependsOn: ["event"]
            ),
        ]
        let outcome = await makeValidator().validate(
            ActionPlan(requestID: requestID, actions: actions),
            context: ValidationContext()
        )

        guard case .ready(let executable) = outcome else {
            Issue.record("Expected ready, got \(outcome)")
            return
        }
        #expect(executable.waves == [["event"], ["reminder"]])
    }

    // MARK: - Search

    @Test("\"What's on my calendar tomorrow\" resolves to tomorrow's window")
    func searchInterval() async throws {
        let outcome = await makeValidator().validate(
            plan(.calendarSearch(SearchParameters(query: EntityQuery(scope: .calendar, day: .tomorrow)))),
            context: ValidationContext()
        )
        guard case .ready(let executable) = outcome,
              case .searchEvents(let query) = try #require(executable.actions.first).operation
        else {
            Issue.record("Expected a ready search, got \(outcome)")
            return
        }
        #expect(iso(query.interval.start) == "2026-09-17 00:00")
        #expect(iso(query.interval.end) == "2026-09-18 00:00")
    }
}

private extension ValidationOutcome {
    /// Convenience for assertions that only care that the plan was refused.
    var rejectionMessage: String? {
        guard case .rejected(let failure) = self else { return nil }
        return failure.userMessage
    }
}
