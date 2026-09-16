import Foundation

/// Conversation state validation needs in order to resolve references.
public struct ValidationContext: Sendable {
    public var references: ReferenceContext
    /// Whether `ActionHistory` currently holds something reversible.
    public var hasUndoableAction: Bool

    public init(references: ReferenceContext = .empty, hasUndoableAction: Bool = false) {
        self.references = references
        self.hasUndoableAction = hasUndoableAction
    }
}

/// Layers 2 through 6 of validation: semantics, business rules, permissions,
/// conflicts and confirmation.
///
/// It turns an `ActionPlan` — which describes intent — into an `ExecutablePlan`
/// whose every parameter has been resolved against real records, or into a
/// single question. Nothing reaches a tool until this type says so.
public struct PlanValidator: Sendable {
    let calendarService: any CalendarService
    let reminderService: any ReminderService
    let temporal: TemporalEngine
    let preferences: SARAPreferences
    private let schemaValidator: PlanSchemaValidator
    let phrasing: DatePhrasing
    /// Used only to order the options in a disambiguation question. SARA still
    /// asks — a remembered choice changes what is offered first, never what is
    /// chosen for the user.
    let memory: (any MemoryStore)?

    public init(
        calendarService: any CalendarService,
        reminderService: any ReminderService,
        temporal: TemporalEngine,
        preferences: SARAPreferences = .default,
        schemaValidator: PlanSchemaValidator = PlanSchemaValidator(),
        memory: (any MemoryStore)? = nil
    ) {
        self.calendarService = calendarService
        self.reminderService = reminderService
        self.temporal = temporal
        self.preferences = preferences
        self.schemaValidator = schemaValidator
        self.phrasing = DatePhrasing(calendar: temporal.calendar)
        self.memory = memory
    }

    // MARK: - Entry point

    public func validate(_ plan: ActionPlan, context: ValidationContext) async -> ValidationOutcome {
        do {
            try schemaValidator.validate(plan)
        } catch let failure as ValidationFailure {
            return .rejected(failure)
        } catch {
            return .rejected(.emptyPlan)
        }

        if let failure = await checkPermissions(for: plan) {
            return .rejected(failure)
        }

        var executable: [ExecutableAction] = []
        var confirmations: [ConfirmationRequest] = []

        for action in plan.actions {
            let result: ActionValidationResult
            do {
                result = try await validate(action, context: context)
            } catch let failure as ValidationFailure {
                return .rejected(failure)
            } catch let error as TemporalError {
                return .rejected(.temporal(error))
            } catch {
                return .rejected(.targetNotFound(description: "what you meant"))
            }

            switch result {
            case .clarify(let request):
                return .needsClarification(request)
            case .resolved(let operation, let confirmation):
                executable.append(
                    ExecutableAction(id: action.id, operation: operation, dependsOn: action.dependsOn)
                )
                if let confirmation { confirmations.append(confirmation) }
            }
        }

        guard let waves = plan.executionWaves() else {
            return .rejected(.invalidDependencyGraph)
        }

        let executablePlan = ExecutablePlan(
            planID: plan.planID,
            requestID: plan.requestID,
            actions: executable,
            waves: waves.map { $0.map(\.id) }
        )

        // A plan the user already agreed to is not asked about again.
        if plan.confirmationState == .confirmed || confirmations.isEmpty {
            return .ready(executablePlan)
        }
        return .needsConfirmation(combine(confirmations), executablePlan)
    }

    // MARK: - Per-action validation

    private enum ActionValidationResult {
        case resolved(ExecutableOperation, ConfirmationRequest?)
        case clarify(ClarificationRequest)
    }

    private func validate(
        _ action: PlannedAction,
        context: ValidationContext
    ) async throws -> ActionValidationResult {
        switch action.payload {
        case .calendarCreate(let parameters):
            return try await validateCalendarCreate(parameters, actionID: action.id)
        case .calendarSearch(let parameters):
            return try validateCalendarSearch(parameters)
        case .calendarUpdate(let parameters):
            return try await validateCalendarUpdate(parameters, actionID: action.id, context: context)
        case .calendarDelete(let parameters):
            return try await validateCalendarDelete(parameters, actionID: action.id, context: context)
        case .reminderCreate(let parameters):
            return try await validateReminderCreate(parameters, actionID: action.id)
        case .reminderSearch(let parameters):
            return try validateReminderSearch(parameters)
        case .reminderUpdate(let parameters):
            return try await validateReminderUpdate(parameters, actionID: action.id, context: context)
        case .reminderDelete(let parameters):
            return try await validateReminderDelete(parameters, actionID: action.id, context: context)
        case .undo:
            guard context.hasUndoableAction else { throw ValidationFailure.nothingToUndo }
            return .resolved(.undoLastAction, nil)
        }
    }

    // MARK: Calendar create

    private func validateCalendarCreate(
        _ parameters: CalendarCreateParameters,
        actionID: ActionID
    ) async throws -> ActionValidationResult {
        let title = parameters.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .clarify(ClarificationRequest(
                subject: .eventTitle,
                question: "What should I call the event?",
                actionID: actionID
            ))
        }
        guard let when = parameters.when, let day = when.day else {
            return .clarify(ClarificationRequest(
                subject: .eventDate,
                question: "When is it?",
                actionID: actionID
            ))
        }
        // An event without a start time cannot be placed, and guessing one
        // would silently invent a commitment.
        if when.time == .unspecified, !parameters.isAllDay {
            return .clarify(ClarificationRequest(
                subject: .eventTime,
                question: "What time should I schedule it?",
                actionID: actionID
            ))
        }

        let resolved: ResolvedDateTime
        do {
            resolved = try temporal.resolve(day: day, time: when.time)
        } catch let error as TemporalError {
            if case .ambiguous(let question, _) = error {
                return .clarify(ClarificationRequest(
                    subject: .whichDate,
                    question: question,
                    actionID: actionID
                ))
            }
            throw error
        }

        let durationMinutes = parameters.durationMinutes
            ?? Int(preferences.temporal.defaultEventDuration / 60)
        guard durationMinutes > 0 else {
            throw ValidationFailure.nonPositiveDuration(durationMinutes)
        }
        let end = resolved.date.addingTimeInterval(Double(durationMinutes) * 60)

        let calendarChoice = try await resolveCalendar(
            id: parameters.calendarID,
            named: parameters.calendarName,
            actionID: actionID
        )
        guard case .one(let calendar) = calendarChoice else {
            if case .ask(let request) = calendarChoice { return .clarify(request) }
            throw ValidationFailure.noWritableContainer
        }

        var alerts = parameters.alertMinutesBefore.map(AlertOffset.minutes)
        if alerts.isEmpty, let defaultAlert = preferences.defaultEventAlertMinutes {
            alerts = [.minutes(defaultAlert)]
        }

        let draft = CalendarEventDraft(
            title: title,
            start: resolved.date,
            end: end,
            isAllDay: parameters.isAllDay,
            calendarID: calendar.id,
            location: parameters.location,
            notes: parameters.notes,
            alerts: alerts,
            recurrence: parameters.recurrence
        )

        let clashes = try await conflicts(for: DateInterval(start: draft.start, end: draft.end))
        let confirmation = clashes.isEmpty ? nil : conflictConfirmation(
            for: title,
            at: draft.start,
            conflicts: clashes
        )
        return .resolved(.createEvent(draft), confirmation)
    }

    // MARK: Calendar search

    private func validateCalendarSearch(_ parameters: SearchParameters) throws -> ActionValidationResult {
        let interval = try searchInterval(for: parameters.query)
        let query = EventSearchQuery(
            interval: interval,
            titleContains: parameters.query.titleContains
        )
        return .resolved(.searchEvents(query), nil)
    }

    // MARK: Calendar update

    private func validateCalendarUpdate(
        _ parameters: UpdateParameters<EventChangeSpec>,
        actionID: ActionID,
        context: ValidationContext
    ) async throws -> ActionValidationResult {
        guard !parameters.changes.isEmpty else {
            throw ValidationFailure.targetNotFound(description: "anything to change")
        }

        let candidates = try await resolveEvents(parameters.target, context: context)
        switch candidates.count {
        case 0:
            throw ValidationFailure.targetNotFound(description: describe(parameters.target, scope: .calendar))
        case 1:
            break
        default:
            return .clarify(disambiguation(events: candidates, reminders: [], actionID: actionID))
        }

        let target = candidates[0]
        var changes = CalendarEventChanges()
        if let title = parameters.changes.title { changes.title = title }
        if let location = parameters.changes.location { changes.location = location }
        if let notes = parameters.changes.notes { changes.notes = notes }
        if let alerts = parameters.changes.alertMinutesBefore {
            changes.alerts = alerts.map(AlertOffset.minutes)
        }

        // Moving an event keeps its length unless a new one was stated.
        var newStart = target.start
        if let when = parameters.changes.when {
            // "Move it to 6 PM" keeps the event's own day when the change names
            // only a time.
            let day = when.day ?? dateSpec(of: target.start)
            let resolved: ResolvedDateTime
            do {
                resolved = try temporal.resolve(
                    day: day,
                    time: when.time,
                    defaultTime: clockComponents(of: target.start)
                )
            } catch let error as TemporalError {
                if case .ambiguous(let question, _) = error {
                    return .clarify(ClarificationRequest(subject: .whichDate, question: question, actionID: actionID))
                }
                throw error
            }
            newStart = resolved.date
            changes.start = newStart
            changes.end = newStart.addingTimeInterval(target.duration)
        }
        if let durationMinutes = parameters.changes.durationMinutes {
            guard durationMinutes > 0 else { throw ValidationFailure.nonPositiveDuration(durationMinutes) }
            changes.end = newStart.addingTimeInterval(Double(durationMinutes) * 60)
        }

        var confirmation: ConfirmationRequest?
        if parameters.changes.calendarName != nil || parameters.changes.calendarID != nil {
            let choice = try await resolveCalendar(
                id: parameters.changes.calendarID,
                named: parameters.changes.calendarName,
                actionID: actionID
            )
            guard case .one(let calendar) = choice else {
                if case .ask(let request) = choice { return .clarify(request) }
                throw ValidationFailure.noWritableContainer
            }
            changes.calendarID = calendar.id
            // Moving between calendars changes who can see the event, so it is
            // always confirmed.
            confirmation = ConfirmationRequest(
                reason: .consequentialChange,
                summary: "Move \(target.title) to the \(calendar.title) calendar",
                question: "Move \(target.title) to the \(calendar.title) calendar?"
            )
        }

        if confirmation == nil, let start = changes.start, let end = changes.end {
            let clashes = try await conflicts(for: DateInterval(start: start, end: end), excluding: target.id)
            if !clashes.isEmpty {
                confirmation = conflictConfirmation(for: target.title, at: start, conflicts: clashes)
            }
        }

        let span: EventSpan = target.isRecurring ? .thisEvent : .thisEvent
        return .resolved(.updateEvent(target: target, changes: changes, span: span), confirmation)
    }

    // MARK: Calendar delete

    private func validateCalendarDelete(
        _ parameters: DeleteParameters,
        actionID: ActionID,
        context: ValidationContext
    ) async throws -> ActionValidationResult {
        let candidates = try await resolveEvents(parameters.target, context: context)
        switch candidates.count {
        case 0:
            throw ValidationFailure.targetNotFound(description: describe(parameters.target, scope: .calendar))
        case 1:
            break
        default:
            return .clarify(disambiguation(events: candidates, reminders: [], actionID: actionID))
        }

        let target = candidates[0]
        let span: EventSpan = parameters.includeFutureOccurrences ? .futureEvents : .thisEvent
        let description = phrasing.describe(target, relativeTo: temporal.now)

        let confirmation = ConfirmationRequest(
            reason: .destructive,
            summary: "Delete \(description)",
            question: "I found \(description). Do you want me to delete it?"
        )
        return .resolved(.deleteEvent(target: target, span: span), confirmation)
    }

    // MARK: Reminder create

    private func validateReminderCreate(
        _ parameters: ReminderCreateParameters,
        actionID: ActionID
    ) async throws -> ActionValidationResult {
        let title = parameters.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .clarify(ClarificationRequest(
                subject: .reminderTitle,
                question: "What should I remind you about?",
                actionID: actionID
            ))
        }

        var dueDate: Date?
        var hasTime = true
        if let due = parameters.due {
            guard let dueDay = due.day else {
                return .clarify(ClarificationRequest(
                    subject: .reminderDueDate,
                    question: "When should I remind you?",
                    actionID: actionID
                ))
            }
            let resolved: ResolvedDateTime
            do {
                // Unlike events, a reminder without a stated time may use the
                // configured default — it does not place a commitment.
                resolved = try temporal.resolve(
                    day: dueDay,
                    time: due.time,
                    defaultTime: (
                        hour: preferences.temporal.defaultReminderHour,
                        minute: preferences.temporal.defaultReminderMinute
                    )
                )
            } catch let error as TemporalError {
                if case .ambiguous(let question, _) = error {
                    return .clarify(ClarificationRequest(subject: .whichDate, question: question, actionID: actionID))
                }
                throw error
            }
            dueDate = resolved.date
            hasTime = true
        }

        let listChoice = try await resolveReminderList(
            id: parameters.listID,
            named: parameters.listName,
            actionID: actionID
        )
        guard case .one(let list) = listChoice else {
            if case .ask(let request) = listChoice { return .clarify(request) }
            throw ValidationFailure.noWritableContainer
        }

        var alerts = parameters.alertMinutesBefore.map(AlertOffset.minutes)
        if alerts.isEmpty, dueDate != nil, let defaultAlert = preferences.defaultReminderAlertMinutes {
            alerts = [.minutes(defaultAlert)]
        }

        let draft = ReminderDraft(
            title: title,
            dueDate: dueDate,
            hasTimeComponent: dueDate != nil && hasTime,
            listID: list.id,
            notes: parameters.notes,
            alerts: alerts
        )
        return .resolved(.createReminder(draft), nil)
    }

    // MARK: Reminder search

    private func validateReminderSearch(_ parameters: SearchParameters) throws -> ActionValidationResult {
        let interval = parameters.query.day == nil ? nil : try searchInterval(for: parameters.query)
        let query = ReminderSearchQuery(
            interval: interval,
            titleContains: parameters.query.titleContains,
            completion: parameters.query.includeCompleted ? .all : .incompleteOnly
        )
        return .resolved(.searchReminders(query), nil)
    }

    // MARK: Reminder update

    private func validateReminderUpdate(
        _ parameters: UpdateParameters<ReminderChangeSpec>,
        actionID: ActionID,
        context: ValidationContext
    ) async throws -> ActionValidationResult {
        guard !parameters.changes.isEmpty else {
            throw ValidationFailure.targetNotFound(description: "anything to change")
        }

        let candidates = try await resolveReminders(parameters.target, context: context)
        switch candidates.count {
        case 0:
            throw ValidationFailure.targetNotFound(description: describe(parameters.target, scope: .reminders))
        case 1:
            break
        default:
            return .clarify(disambiguation(events: [], reminders: candidates, actionID: actionID))
        }

        let target = candidates[0]
        var changes = ReminderChanges()
        if let title = parameters.changes.title { changes.title = title }
        if let notes = parameters.changes.notes { changes.notes = notes }
        if let completed = parameters.changes.markCompleted { changes.isCompleted = completed }
        if let alerts = parameters.changes.alertMinutesBefore { changes.alerts = alerts.map(AlertOffset.minutes) }
        if parameters.changes.clearDue { changes.clearDueDate = true }

        if let due = parameters.changes.due {
            let fallback = target.dueDate.map(clockComponents(of:))
                ?? (
                    hour: preferences.temporal.defaultReminderHour,
                    minute: preferences.temporal.defaultReminderMinute
                )
            let day = due.day ?? target.dueDate.map(dateSpec(of:)) ?? .today
            let resolved: ResolvedDateTime
            do {
                resolved = try temporal.resolve(day: day, time: due.time, defaultTime: fallback)
            } catch let error as TemporalError {
                if case .ambiguous(let question, _) = error {
                    return .clarify(ClarificationRequest(subject: .whichDate, question: question, actionID: actionID))
                }
                throw error
            }
            changes.dueDate = resolved.date
            changes.hasTimeComponent = true
        }

        if parameters.changes.listName != nil || parameters.changes.listID != nil {
            let choice = try await resolveReminderList(
                id: parameters.changes.listID,
                named: parameters.changes.listName,
                actionID: actionID
            )
            guard case .one(let list) = choice else {
                if case .ask(let request) = choice { return .clarify(request) }
                throw ValidationFailure.noWritableContainer
            }
            changes.listID = list.id
        }

        return .resolved(.updateReminder(target: target, changes: changes), nil)
    }

    // MARK: Reminder delete

    private func validateReminderDelete(
        _ parameters: DeleteParameters,
        actionID: ActionID,
        context: ValidationContext
    ) async throws -> ActionValidationResult {
        let candidates = try await resolveReminders(parameters.target, context: context)
        switch candidates.count {
        case 0:
            throw ValidationFailure.targetNotFound(description: describe(parameters.target, scope: .reminders))
        case 1:
            break
        default:
            return .clarify(disambiguation(events: [], reminders: candidates, actionID: actionID))
        }

        let target = candidates[0]
        let description = phrasing.describe(target, relativeTo: temporal.now)
        let confirmation = ConfirmationRequest(
            reason: .destructive,
            summary: "Delete the reminder \(description)",
            question: "I found the reminder \(description). Do you want me to delete it?"
        )
        return .resolved(.deleteReminder(target: target), confirmation)
    }
}
