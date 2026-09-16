import Foundation

/// Deterministic, on-device interpretation of the commands SARA sees most.
///
/// This is the first stop in routing: creating, finding, moving and deleting
/// events and reminders follows regular enough phrasing that a language model
/// adds cost and latency without adding correctness. Anything it cannot parse
/// confidently it declines, and the router escalates.
public struct LocalCommandInterpreter: AIProvider {
    private let phrases = TemporalPhraseParser()

    public init() {}

    public let identifier = "local.deterministic"

    public let capabilities = ProviderCapabilities(
        isOnDevice: true,
        requiresNetwork: false,
        reasoningStrength: 0.25,
        relativeCost: 0,
        typicalLatency: .milliseconds(1)
    )

    public func isAvailable() async -> Bool { true }

    public func interpret(_ input: AIInput) async throws -> AIResult {
        guard let result = parse(input.request) else {
            throw AIProviderError.malformedResponse(detail: "no deterministic match")
        }
        return result
    }

    /// Returns `nil` when the phrasing is outside what this parser handles.
    public func parse(_ request: UserRequest) -> AIResult? {
        let text = request.normalizedText
        guard !text.isEmpty else { return nil }

        if isUndo(text) {
            return .plan(makePlan(request, [
                PlannedAction(id: "undo", payload: .undo(UndoParameters()))
            ]))
        }
        if let scope = searchScope(text) {
            return .plan(makePlan(request, searchActions(text, scope: scope)))
        }
        if let action = deleteAction(text) {
            return .plan(makePlan(request, [action]))
        }
        if let action = updateAction(text) {
            return .plan(makePlan(request, [action]))
        }
        if let actions = createActions(text) {
            return .plan(makePlan(request, actions))
        }
        return nil
    }

    private func makePlan(_ request: UserRequest, _ actions: [PlannedAction]) -> ActionPlan {
        // Deterministic parses are certain by construction: the phrasing either
        // matched or it did not.
        ActionPlan(requestID: request.id, actions: actions, confidence: 1.0)
    }

    // MARK: - Undo

    private func isUndo(_ text: String) -> Bool {
        text.wholeMatch(of: /\s*(undo|undo that|undo it|take that back|never mind,? undo( that)?)\s*[.!]?\s*/.ignoresCase()) != nil
    }

    // MARK: - Search

    private func searchScope(_ text: String) -> EntityScope? {
        if text.firstMatch(of: /\bwhat('?s| is| are)?\s+(on\s+)?(my\s+)?(calendar|schedule|agenda)\b/.ignoresCase()) != nil {
            return .calendar
        }
        if text.firstMatch(of: /\b(do|have)\s+i\s+have\s+(anything|any\s+events?|any\s+meetings?)\b/.ignoresCase()) != nil {
            return .calendar
        }
        if text.firstMatch(of: /\bwhat\s+do\s+i\s+(need\s+to|have\s+to)\s+do\b/.ignoresCase()) != nil {
            // "What do I need to do?" spans both sources; the answer preserves
            // which items are events and which are reminders.
            return .both
        }
        if text.firstMatch(of: /\bwhat\s+(are\s+)?(my\s+)?reminders?\b|\bwhat('?s| is)\s+on\s+my\s+(list|to-?do)\b/.ignoresCase()) != nil {
            return .reminders
        }
        if text.firstMatch(of: /\b(show|list|tell)\s+me\s+(my\s+)?(events?|meetings?|schedule|calendar)\b/.ignoresCase()) != nil {
            return .calendar
        }
        if text.firstMatch(of: /\b(show|list|tell)\s+me\s+(my\s+)?(reminders?|tasks?)\b/.ignoresCase()) != nil {
            return .reminders
        }
        return nil
    }

    private func searchActions(_ text: String, scope: EntityScope) -> [PlannedAction] {
        let day = phrases.findDay(in: text)?.value
        let query = EntityQuery(scope: scope, day: day ?? .today)

        switch scope {
        case .calendar:
            return [PlannedAction(id: "search", payload: .calendarSearch(SearchParameters(query: query)))]
        case .reminders:
            return [PlannedAction(id: "search", payload: .reminderSearch(SearchParameters(query: query)))]
        case .both:
            return [
                PlannedAction(id: "search-events", payload: .calendarSearch(SearchParameters(query: query))),
                PlannedAction(id: "search-reminders", payload: .reminderSearch(SearchParameters(query: query))),
            ]
        }
    }

    // MARK: - Delete

    private func deleteAction(_ text: String) -> PlannedAction? {
        guard let verb = text.firstMatch(
            of: /^\s*(please\s+)?(delete|cancel|remove|get\s+rid\s+of)\s+/.ignoresCase()
        ) else { return nil }

        var remainder = String(text[verb.range.upperBound...])
        let isReminder = Self.mentionsReminder(remainder)
        let day = phrases.findDay(in: remainder)
        if let day { remainder = Self.removing(day.range, from: remainder) }

        if let reference = Self.reference(in: remainder) {
            let query = EntityQuery(
                scope: isReminder ? .reminders : .calendar,
                day: day?.value,
                reference: reference
            )
            return PlannedAction(
                id: "delete",
                payload: isReminder
                    ? .reminderDelete(DeleteParameters(target: query))
                    : .calendarDelete(DeleteParameters(target: query))
            )
        }

        let title = Self.cleanTitle(Self.strippingKindMarker(remainder))
        guard !title.isEmpty else { return nil }

        let query = EntityQuery(
            scope: isReminder ? .reminders : .calendar,
            titleContains: title,
            day: day?.value
        )
        return PlannedAction(
            id: "delete",
            payload: isReminder
                ? .reminderDelete(DeleteParameters(target: query))
                : .calendarDelete(DeleteParameters(target: query))
        )
    }

    // MARK: - Update

    private func updateAction(_ text: String) -> PlannedAction? {
        guard let verb = text.firstMatch(
            of: /^\s*(please\s+)?(move|reschedule|change|push|shift|make)\s+/.ignoresCase()
        ) else { return nil }

        let body = String(text[verb.range.upperBound...])

        // "Move gym tomorrow from 2 PM to 6 PM" — the stated old time describes
        // the target, and only the text after the final "to" is the change.
        guard let separator = body.ranges(of: /\s+to\s+/.ignoresCase()).last else { return nil }
        var targetText = String(body[body.startIndex..<separator.lowerBound])
        let changeText = String(body[separator.upperBound...])

        // "from 2 PM" narrows which occurrence is meant; it is part of the
        // target description, not of the change.
        var statedCurrentTime: TimeSpec?
        if let from = targetText.firstMatch(of: /\s+from\s+(.+)$/.ignoresCase()) {
            statedCurrentTime = phrases.findTime(in: String(from.1))?.value
            targetText = String(targetText[targetText.startIndex..<from.range.lowerBound])
        }

        let isReminder = Self.mentionsReminder(targetText)
        let targetDay = phrases.findDay(in: targetText)
        if let targetDay { targetText = Self.removing(targetDay.range, from: targetText) }
        let targetTime = phrases.findTime(in: targetText)
        if let targetTime { targetText = Self.removing(targetTime.range, from: targetText) }

        let changeDay = phrases.findDay(in: changeText)?.value
        let changeTime = phrases.findTime(in: changeText)?.value
        guard changeDay != nil || changeTime != nil else { return nil }

        let reference = Self.reference(in: targetText)
        let title = Self.cleanTitle(Self.strippingKindMarker(targetText))
        guard reference != nil || !title.isEmpty else { return nil }

        let target = EntityQuery(
            scope: isReminder ? .reminders : .calendar,
            titleContains: reference == nil ? title : nil,
            day: targetDay?.value,
            time: statedCurrentTime ?? targetTime?.value,
            reference: reference
        )
        let when = DateTimeSpec(day: changeDay, time: changeTime ?? .unspecified)

        if isReminder {
            return PlannedAction(
                id: "update",
                payload: .reminderUpdate(UpdateParameters(
                    target: target,
                    changes: ReminderChangeSpec(due: when)
                ))
            )
        }
        return PlannedAction(
            id: "update",
            payload: .calendarUpdate(UpdateParameters(
                target: target,
                changes: EventChangeSpec(when: when)
            ))
        )
    }

    // MARK: - Create

    private func createActions(_ text: String) -> [PlannedAction]? {
        // "... and remind me to X" is a second, dependent action. "... and
        // remind me 30 minutes before" is an alert on the event being created.
        var primary = text
        var trailingReminder: String?
        if let split = text.firstMatch(of: /\s+and\s+(?=remind\s+me\s+to\b)/.ignoresCase()) {
            primary = String(text[text.startIndex..<split.range.lowerBound])
            trailingReminder = String(text[split.range.upperBound...])
        }

        guard var action = reminderCreateAction(primary) ?? eventCreateAction(primary) else {
            return nil
        }
        action = PlannedAction(id: "primary", payload: action.payload)

        guard let trailingReminder, let follower = reminderCreateAction(trailingReminder) else {
            return [action]
        }
        return [
            action,
            PlannedAction(id: "follow-up", payload: follower.payload, dependsOn: ["primary"]),
        ]
    }

    private func reminderCreateAction(_ text: String) -> PlannedAction? {
        guard let verb = text.firstMatch(
            of: /^\s*(please\s+)?(remind\s+me\s+(to|about)|set\s+a\s+reminder\s+(to|about|for)|add\s+a\s+reminder\s+(to|about|for))\s+/.ignoresCase()
        ) else { return nil }

        var remainder = String(text[verb.range.upperBound...])
        let list = phrases.findContainerName(in: remainder)
        if let list { remainder = Self.removing(list.range, from: remainder) }
        let day = phrases.findDay(in: remainder)
        if let day { remainder = Self.removing(day.range, from: remainder) }
        let time = phrases.findTime(in: remainder)
        if let time { remainder = Self.removing(time.range, from: remainder) }

        let title = Self.cleanTitle(remainder)
        guard !title.isEmpty else { return nil }

        let due: DateTimeSpec? = (day != nil || time != nil)
            ? DateTimeSpec(day: day?.value, time: time?.value ?? .unspecified)
            : nil

        return PlannedAction(
            id: "reminder",
            payload: .reminderCreate(ReminderCreateParameters(
                title: title,
                due: due,
                listName: list?.value
            ))
        )
    }

    private func eventCreateAction(_ text: String) -> PlannedAction? {
        guard let verb = text.firstMatch(
            of: /^\s*(please\s+)?(schedule|book|create|add|set\s+up|put|plan)\s+/.ignoresCase()
        ) else { return nil }

        var remainder = String(text[verb.range.upperBound...])
        remainder = remainder.replacing(/^(an?\s+event\s+(called|named|for)?\s*|a\s+meeting\s+(called|named|for)?\s*)/.ignoresCase(), with: "")

        let calendarName = phrases.findContainerName(in: remainder)
        if let calendarName { remainder = Self.removing(calendarName.range, from: remainder) }
        let recurrence = phrases.findRecurrence(in: remainder)
        if let recurrence { remainder = Self.removing(recurrence.range, from: remainder) }
        let alert = phrases.findAlert(in: remainder)
        if let alert { remainder = Self.removing(alert.range, from: remainder) }
        let duration = phrases.findDuration(in: remainder)
        if let duration { remainder = Self.removing(duration.range, from: remainder) }
        let day = phrases.findDay(in: remainder)
        if let day { remainder = Self.removing(day.range, from: remainder) }
        let time = phrases.findTime(in: remainder)
        if let time { remainder = Self.removing(time.range, from: remainder) }

        let title = Self.cleanTitle(remainder)
        guard !title.isEmpty else { return nil }

        let when: DateTimeSpec? = (day != nil || time != nil)
            ? DateTimeSpec(day: day?.value, time: time?.value ?? .unspecified)
            : nil

        return PlannedAction(
            id: "event",
            payload: .calendarCreate(CalendarCreateParameters(
                title: title,
                when: when,
                durationMinutes: duration?.value,
                calendarName: calendarName?.value,
                alertMinutesBefore: alert.map { [$0.value] } ?? [],
                recurrence: recurrence?.value
            ))
        )
    }

    // MARK: - Text helpers

    private static func mentionsReminder(_ text: String) -> Bool {
        text.firstMatch(of: /\breminders?\b/.ignoresCase()) != nil
    }

    /// Strips a leading kind marker from a target description.
    ///
    /// In "the reminder to call John", "reminder" says which *kind* of record
    /// to look for, not what it is called — leaving it in means searching for a
    /// reminder whose title contains "reminder to call John", which never
    /// matches. The connective ("to", "called", "about") is what marks the rest
    /// as the name, so a bare "my meeting" keeps "meeting" as its title.
    static func strippingKindMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(
            of: /^(?:the\s+|a\s+|an\s+|my\s+)?(?:reminder|event|meeting|appointment|task)s?\s+(?:to|about|for|called|named|titled)\s+(.+)$/.ignoresCase()
        ) else { return text }

        return String(match.1)
    }

    /// Recognises "it", "that" and "the second one" as pointers into context.
    private static func reference(in text: String) -> EntityReference? {
        if text.firstMatch(of: /\b(the\s+)?(first|second|third|fourth|fifth|last)\s+one\b/.ignoresCase()) != nil {
            let word = text.firstMatch(of: /\b(first|second|third|fourth|fifth|last)\b/.ignoresCase()).map { String($0.1).lowercased() }
            if let word, let ordinal = TemporalPhraseParser.ordinals[word], ordinal > 0 {
                return .ordinal(ordinal)
            }
        }
        if text.wholeMatch(of: /\s*(it|that|this|that\s+one)\s*/.ignoresCase()) != nil {
            return .lastMentioned
        }
        return nil
    }

    private static func removing(_ range: Range<String.Index>, from text: String) -> String {
        var copy = text
        copy.removeSubrange(range)
        return copy
    }

    /// Strips the connective words left behind once temporal phrases are
    /// removed, so "Gym" survives but "a gym session on my calendar" loses its
    /// scaffolding rather than its meaning.
    static func cleanTitle(_ text: String) -> String {
        var result = text
        result = result.replacing(/\b(on|in|to)\s+my\s+(calendar|schedule|reminders?|list)\b/.ignoresCase(), with: "")
        result = result.replacing(/\bplease\b/.ignoresCase(), with: "")
        result = result.replacing(/^\s*(an?|the|my)\s+/.ignoresCase(), with: "")
        result = result.replacing(/\s+(on|at|for|to|in|and)\s*$/.ignoresCase(), with: "")
        result = result.replacing(/^\s*(on|at|for|to|in|and)\s+/.ignoresCase(), with: "")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:-"))
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
