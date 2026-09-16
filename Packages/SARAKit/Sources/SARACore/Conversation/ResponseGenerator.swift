import Foundation

/// What SARA says, plus what it should now consider "presented" for reference
/// resolution.
public struct SARAResponse: Sendable {
    public let text: String
    public let kind: ConversationMessage.Kind
    /// Records the user was just shown, in the order they were shown, so "the
    /// second one" means something.
    public let presentedEvents: [CalendarEvent]
    public let presentedReminders: [Reminder]
    /// The record SARA just created or changed, which "it" now refers to.
    public let touchedEvent: CalendarEvent?
    public let touchedReminder: Reminder?

    public init(
        text: String,
        kind: ConversationMessage.Kind = .standard,
        presentedEvents: [CalendarEvent] = [],
        presentedReminders: [Reminder] = [],
        touchedEvent: CalendarEvent? = nil,
        touchedReminder: Reminder? = nil
    ) {
        self.text = text
        self.kind = kind
        self.presentedEvents = presentedEvents
        self.presentedReminders = presentedReminders
        self.touchedEvent = touchedEvent
        self.touchedReminder = touchedReminder
    }
}

/// Turns verified outcomes into SARA's voice: calm, concise, and specific.
///
/// Length follows the situation — a completed simple action gets a word or two,
/// a partial failure gets the exact detail — and every claim comes from a
/// record that was read back from EventKit.
public struct ResponseGenerator: Sendable {
    private let dateProvider: DateProvider
    private let phrasing: DatePhrasing

    public init(dateProvider: DateProvider) {
        self.dateProvider = dateProvider
        self.phrasing = DatePhrasing(calendar: dateProvider.calendar)
    }

    // MARK: - Execution

    public func response(for report: ExecutionReport) -> SARAResponse {
        let now = dateProvider.now
        var presentedEvents: [CalendarEvent] = []
        var presentedReminders: [Reminder] = []
        var touchedEvent: CalendarEvent?
        var touchedReminder: Reminder?
        var sentences: [String] = []

        for result in report.successes {
            switch result {
            case .createdEvent(let event):
                touchedEvent = event
                sentences.append("\(event.title) is on your calendar \(phrasing.dayAndTime(event.start, relativeTo: now, includeTime: !event.isAllDay))")
            case .createdReminder(let reminder):
                touchedReminder = reminder
                if let due = reminder.dueDate {
                    sentences.append("I'll remind you to \(reminder.title) \(phrasing.dayAndTime(due, relativeTo: now, includeTime: reminder.hasTimeComponent))")
                } else {
                    sentences.append("I've added a reminder to \(reminder.title)")
                }
            case .updatedEvent(_, let after):
                touchedEvent = after
                sentences.append("\(after.title) is now \(phrasing.dayAndTime(after.start, relativeTo: now, includeTime: !after.isAllDay))")
            case .updatedReminder(_, let after):
                touchedReminder = after
                sentences.append(updatedReminderSentence(after, now: now))
            case .deletedEvent(let event):
                sentences.append("I've deleted \(event.title)")
            case .deletedReminder(let reminder):
                sentences.append("I've deleted the reminder to \(reminder.title)")
            case .foundEvents(let events):
                presentedEvents = events
            case .foundReminders(let reminders):
                presentedReminders = reminders
            case .undone(let summary):
                sentences.append("I've undone \(summary)")
            }
        }

        let isSearch = !report.successes.isEmpty && report.successes.allSatisfy(Self.isSearch)
        if isSearch, report.failures.isEmpty {
            return SARAResponse(
                text: searchSummary(events: presentedEvents, reminders: presentedReminders, now: now),
                presentedEvents: presentedEvents,
                presentedReminders: presentedReminders
            )
        }

        let failureText = report.failures
            .map { $0.wasSkipped ? "and I skipped the rest because \($0.message)" : $0.message }

        if report.allSucceeded {
            let body = Self.join(sentences)
            return SARAResponse(
                text: body.isEmpty ? "Done." : "Done. \(Self.sentence(body))",
                kind: .success,
                presentedEvents: presentedEvents,
                presentedReminders: presentedReminders,
                touchedEvent: touchedEvent,
                touchedReminder: touchedReminder
            )
        }

        if report.allFailed {
            return SARAResponse(
                text: failureText.first ?? "I couldn't do that.",
                kind: .failure
            )
        }

        // Partial success is stated as partial: what worked, then what did not.
        // Two sentences rather than one clause, so a failure message that
        // starts with "I" is not mangled into the middle of a sentence.
        let done = Self.sentence(Self.join(sentences))
        let failed = Self.sentence(Self.join(failureText))
        return SARAResponse(
            text: "\(done) \(failed)",
            kind: .failure,
            presentedEvents: presentedEvents,
            presentedReminders: presentedReminders,
            touchedEvent: touchedEvent,
            touchedReminder: touchedReminder
        )
    }

    // MARK: - Questions and failures

    public func response(for clarification: ClarificationRequest) -> SARAResponse {
        guard !clarification.options.isEmpty else {
            return SARAResponse(text: clarification.question, kind: .clarification)
        }
        let list = clarification.options
            .map { "• \($0.label)" }
            .joined(separator: "\n")
        return SARAResponse(
            text: "\(clarification.question)\n\(list)",
            kind: .clarification
        )
    }

    public func response(for confirmation: ConfirmationRequest) -> SARAResponse {
        SARAResponse(text: confirmation.question, kind: .confirmation)
    }

    public func response(for failure: ValidationFailure) -> SARAResponse {
        SARAResponse(text: failure.userMessage, kind: .failure)
    }

    public func response(for error: AIProviderError) -> SARAResponse {
        SARAResponse(text: error.userMessage, kind: .failure)
    }

    // MARK: - Search summaries

    /// Answers a lookup conversationally, keeping events and reminders distinct
    /// and ordering everything by time.
    func searchSummary(events: [CalendarEvent], reminders: [Reminder], now: Date) -> String {
        if events.isEmpty && reminders.isEmpty {
            return "Nothing scheduled."
        }

        var lines: [String] = []
        if !events.isEmpty {
            lines.append(events.count == 1 ? "One event:" : "\(events.count) events:")
            lines += events.map { "• \(phrasing.describe($0, relativeTo: now))" }
        }
        if !reminders.isEmpty {
            lines.append(reminders.count == 1 ? "One reminder:" : "\(reminders.count) reminders:")
            lines += reminders.map { "• \(phrasing.describe($0, relativeTo: now))" }
        }
        return lines.joined(separator: "\n")
    }

    private func updatedReminderSentence(_ reminder: Reminder, now: Date) -> String {
        if reminder.isCompleted {
            return "I've marked \(reminder.title) as done"
        }
        guard let due = reminder.dueDate else {
            return "I've updated the reminder to \(reminder.title)"
        }
        return "I'll remind you to \(reminder.title) \(phrasing.dayAndTime(due, relativeTo: now, includeTime: reminder.hasTimeComponent))"
    }

    private static func isSearch(_ result: ActionResult) -> Bool {
        switch result {
        case .foundEvents, .foundReminders: true
        default: false
        }
    }

    /// Capitalises the opening letter and closes with a full stop, without
    /// touching the casing of anything else — titles keep the user's own
    /// capitalisation.
    static func sentence(_ text: String) -> String {
        guard let first = text.first else { return "" }
        let body = first.uppercased() + text.dropFirst()
        return body.hasSuffix(".") || body.hasSuffix("?") || body.hasSuffix("!")
            ? body
            : body + "."
    }

    static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]), and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + ", and \(parts[parts.count - 1])"
        }
    }
}
