import Foundation

/// What any provider is allowed to conclude about an utterance.
public enum ExtractedIntent: String, Hashable, Sendable, Codable {
    case createEvent
    case createReminder
    case searchCalendar
    case searchReminders
    case searchCalendarAndReminders
    case updateEvent
    case updateReminder
    case deleteEvent
    case deleteReminder
    case undoLastAction
    case smallTalk
    case unsupported
}

/// A provider-neutral extraction: an intent plus the user's own words.
///
/// Every temporal field stays a phrase. Providers are never asked for a date,
/// so a model that hallucinates one has nowhere to put it — the phrase is
/// re-parsed and resolved deterministically in Swift.
public struct ExtractedSlots: Hashable, Sendable {
    public var intent: ExtractedIntent
    public var title: String?
    public var whenPhrase: String?
    public var newWhenPhrase: String?
    public var durationPhrase: String?
    public var alertPhrase: String?
    public var recurrencePhrase: String?
    public var containerName: String?
    public var reply: String?

    public init(
        intent: ExtractedIntent,
        title: String? = nil,
        whenPhrase: String? = nil,
        newWhenPhrase: String? = nil,
        durationPhrase: String? = nil,
        alertPhrase: String? = nil,
        recurrencePhrase: String? = nil,
        containerName: String? = nil,
        reply: String? = nil
    ) {
        self.intent = intent
        self.title = title
        self.whenPhrase = whenPhrase
        self.newWhenPhrase = newWhenPhrase
        self.durationPhrase = durationPhrase
        self.alertPhrase = alertPhrase
        self.recurrencePhrase = recurrencePhrase
        self.containerName = containerName
        self.reply = reply
    }
}

/// Turns provider slots into a typed `ActionPlan`.
///
/// Shared by every provider, so Apple's model, OpenAI and Claude all arrive at
/// the same validated structure and cannot each invent their own semantics.
public struct SlotPlanBuilder: Sendable {
    private let phrases = TemporalPhraseParser()
    /// How confident SARA is in a model extraction, as opposed to a
    /// deterministic parse. Below the validator's floor it will ask instead.
    private let confidence: Double

    public init(confidence: Double = 0.8) {
        self.confidence = confidence
    }

    /// Returns `nil` when the slots do not describe anything executable.
    public func build(_ slots: ExtractedSlots, for request: UserRequest) -> AIResult? {
        switch slots.intent {
        case .smallTalk:
            let reply = slots.reply?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let reply, !reply.isEmpty else { return nil }
            return .conversation(reply)

        case .unsupported:
            return .unsupported(
                reason: "That's outside what I can do — I handle calendar events and reminders."
            )

        case .undoLastAction:
            return plan(request, [PlannedAction(id: "undo", payload: .undo(UndoParameters()))])

        case .createEvent:
            return buildCreateEvent(slots, request: request)

        case .createReminder:
            return buildCreateReminder(slots, request: request)

        case .searchCalendar, .searchReminders, .searchCalendarAndReminders:
            return buildSearch(slots, request: request)

        case .updateEvent, .updateReminder:
            return buildUpdate(slots, request: request)

        case .deleteEvent, .deleteReminder:
            return buildDelete(slots, request: request)
        }
    }

    // MARK: - Builders

    private func buildCreateEvent(_ slots: ExtractedSlots, request: UserRequest) -> AIResult? {
        let parameters = CalendarCreateParameters(
            title: cleaned(slots.title) ?? "",
            when: dateTimeSpec(from: slots.whenPhrase),
            durationMinutes: slots.durationPhrase.flatMap(durationMinutes),
            calendarName: cleaned(slots.containerName),
            alertMinutesBefore: slots.alertPhrase.flatMap(alertMinutes).map { [$0] } ?? [],
            recurrence: slots.recurrencePhrase.flatMap { phrases.findRecurrence(in: $0)?.value }
        )
        return plan(request, [PlannedAction(id: "event", payload: .calendarCreate(parameters))])
    }

    private func buildCreateReminder(_ slots: ExtractedSlots, request: UserRequest) -> AIResult? {
        let parameters = ReminderCreateParameters(
            title: cleaned(slots.title) ?? "",
            due: dateTimeSpec(from: slots.whenPhrase),
            listName: cleaned(slots.containerName),
            alertMinutesBefore: slots.alertPhrase.flatMap(alertMinutes).map { [$0] } ?? []
        )
        return plan(request, [PlannedAction(id: "reminder", payload: .reminderCreate(parameters))])
    }

    private func buildSearch(_ slots: ExtractedSlots, request: UserRequest) -> AIResult? {
        let day = slots.whenPhrase.flatMap { phrases.findDay(in: $0)?.value } ?? .today
        let query = EntityQuery(
            scope: scope(for: slots.intent),
            titleContains: cleaned(slots.title),
            day: day,
            containerName: cleaned(slots.containerName)
        )

        switch slots.intent {
        case .searchReminders:
            return plan(request, [
                PlannedAction(id: "search", payload: .reminderSearch(SearchParameters(query: query)))
            ])
        case .searchCalendarAndReminders:
            return plan(request, [
                PlannedAction(id: "search-events", payload: .calendarSearch(SearchParameters(query: query))),
                PlannedAction(id: "search-reminders", payload: .reminderSearch(SearchParameters(query: query))),
            ])
        default:
            return plan(request, [
                PlannedAction(id: "search", payload: .calendarSearch(SearchParameters(query: query)))
            ])
        }
    }

    private func buildUpdate(_ slots: ExtractedSlots, request: UserRequest) -> AIResult? {
        let isReminder = slots.intent == .updateReminder
        // Without a new time or date there is nothing to change, so this is
        // refused here rather than reaching validation as an empty update.
        guard let when = dateTimeSpec(from: slots.newWhenPhrase) else { return nil }

        let target = targetQuery(slots, scope: isReminder ? .reminders : .calendar)
        guard !target.isUnconstrained else { return nil }

        if isReminder {
            return plan(request, [PlannedAction(
                id: "update",
                payload: .reminderUpdate(UpdateParameters(target: target, changes: ReminderChangeSpec(due: when)))
            )])
        }
        return plan(request, [PlannedAction(
            id: "update",
            payload: .calendarUpdate(UpdateParameters(target: target, changes: EventChangeSpec(when: when)))
        )])
    }

    private func buildDelete(_ slots: ExtractedSlots, request: UserRequest) -> AIResult? {
        let isReminder = slots.intent == .deleteReminder
        let target = targetQuery(slots, scope: isReminder ? .reminders : .calendar)
        // A delete with nothing identifying the target is never built.
        guard !target.isUnconstrained else { return nil }

        return plan(request, [PlannedAction(
            id: "delete",
            payload: isReminder
                ? .reminderDelete(DeleteParameters(target: target))
                : .calendarDelete(DeleteParameters(target: target))
        )])
    }

    // MARK: - Helpers

    private func targetQuery(_ slots: ExtractedSlots, scope: EntityScope) -> EntityQuery {
        let spec = dateTimeSpec(from: slots.whenPhrase)
        return EntityQuery(
            scope: scope,
            titleContains: cleaned(slots.title),
            day: spec?.day,
            time: spec?.time == .unspecified ? nil : spec?.time,
            containerName: cleaned(slots.containerName)
        )
    }

    private func scope(for intent: ExtractedIntent) -> EntityScope {
        switch intent {
        case .searchReminders, .deleteReminder, .updateReminder: .reminders
        case .searchCalendarAndReminders: .both
        default: .calendar
        }
    }

    /// Re-parses the user's own phrase. A phrase the parser does not recognise
    /// becomes "no date said", which makes SARA ask rather than assume.
    private func dateTimeSpec(from phrase: String?) -> DateTimeSpec? {
        guard let phrase = cleaned(phrase) else { return nil }
        let day = phrases.findDay(in: phrase)?.value
        let time = phrases.findTime(in: phrase)?.value
        guard day != nil || time != nil else { return nil }
        return DateTimeSpec(day: day, time: time ?? .unspecified)
    }

    private func durationMinutes(_ phrase: String) -> Int? {
        // The parser expects the "for ..." framing the user would actually use.
        phrases.findDuration(in: phrase.hasPrefix("for ") ? phrase : "for \(phrase)")?.value
    }

    private func alertMinutes(_ phrase: String) -> Int? {
        phrases.findAlert(in: phrase)?.value
    }

    private func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private func plan(_ request: UserRequest, _ actions: [PlannedAction]) -> AIResult {
        .plan(ActionPlan(requestID: request.id, actions: actions, confidence: confidence))
    }
}
