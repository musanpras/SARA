import Foundation

/// Resolution helpers: permissions, containers, targets, conflicts and the
/// wording of the questions SARA asks when something cannot be resolved.
extension PlanValidator {
    // MARK: - Permissions

    /// Requests access for exactly the capabilities this plan needs, and only
    /// at the moment it needs them. Returns a failure when access is refused.
    func checkPermissions(for plan: ActionPlan) async -> ValidationFailure? {
        let types = Set(plan.actions.map(\.type))
        let needsCalendar = types.contains { $0.rawValue.hasPrefix("calendar.") }
        let needsReminders = types.contains { $0.rawValue.hasPrefix("reminder.") }

        if needsCalendar {
            var status = await calendarService.authorizationStatus()
            if status.isPromptable {
                status = await calendarService.requestAccess()
            }
            guard status.canRead else {
                return .permission(PermissionError(capability: .calendar, status: status))
            }
        }

        if needsReminders {
            var status = await reminderService.authorizationStatus()
            if status.isPromptable {
                status = await reminderService.requestAccess()
            }
            guard status.canRead else {
                return .permission(PermissionError(capability: .reminders, status: status))
            }
        }

        return nil
    }

    // MARK: - Containers

    enum CalendarChoice {
        case one(CalendarDescriptor)
        case ask(ClarificationRequest)
    }

    enum ListChoice {
        case one(ReminderListDescriptor)
        case ask(ClarificationRequest)
    }

    /// Picks the calendar to write to: the one named, the configured
    /// preference, or the system default — never an arbitrary one.
    func resolveCalendar(
        id: String? = nil,
        named name: String?,
        actionID: ActionID
    ) async throws -> CalendarChoice {
        let available = try await calendarService.calendars().filter(\.allowsModification)
        guard !available.isEmpty else { throw ValidationFailure.noWritableContainer }

        // An identifier is the user's already-given answer; it is never
        // second-guessed against the name.
        if let id {
            guard let match = available.first(where: { $0.id.rawValue == id }) else {
                throw ValidationFailure.calendarNotFound(name: name ?? id)
            }
            return .one(match)
        }

        if let name = (name ?? preferences.preferredCalendarName)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let matches = Self.match(name: name, in: available.map { ($0.title, $0) })

            switch matches.count {
            case 1:
                return .one(matches[0])
            case 0:
                // A name the user actually spoke must not be silently ignored;
                // a stale stored preference falls back to the default instead.
                if name == preferences.preferredCalendarName { break }
                throw ValidationFailure.calendarNotFound(name: name)
            default:
                let key = MemorySubject.calendarChoice(forName: name)
                let options = matches.map {
                    ClarificationOption(id: $0.id.rawValue, label: $0.qualifiedTitle)
                }
                return .ask(ClarificationRequest(
                    subject: .whichContainer,
                    question: "Which calendar do you mean?",
                    options: await preferredFirst(options, key: key),
                    actionID: actionID,
                    memoryKey: key
                ))
            }
        }

        if let preferred = try await calendarService.defaultCalendar(), preferred.allowsModification {
            return .one(preferred)
        }
        if let fallback = available.first(where: \.isDefaultForNewEvents) ?? available.first {
            return .one(fallback)
        }
        throw ValidationFailure.noWritableContainer
    }

    func resolveReminderList(
        id: String? = nil,
        named name: String?,
        actionID: ActionID
    ) async throws -> ListChoice {
        let available = try await reminderService.lists().filter(\.allowsModification)
        guard !available.isEmpty else { throw ValidationFailure.noWritableContainer }

        if let id {
            guard let match = available.first(where: { $0.id.rawValue == id }) else {
                throw ValidationFailure.reminderListNotFound(name: name ?? id)
            }
            return .one(match)
        }

        if let name = (name ?? preferences.preferredReminderListName)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let matches = Self.match(name: name, in: available.map { ($0.title, $0) })

            switch matches.count {
            case 1:
                return .one(matches[0])
            case 0:
                if name == preferences.preferredReminderListName { break }
                throw ValidationFailure.reminderListNotFound(name: name)
            default:
                let key = MemorySubject.listChoice(forName: name)
                let options = matches.map {
                    ClarificationOption(id: $0.id.rawValue, label: $0.title)
                }
                return .ask(ClarificationRequest(
                    subject: .whichContainer,
                    question: "Which list do you mean?",
                    options: await preferredFirst(options, key: key),
                    actionID: actionID,
                    memoryKey: key
                ))
            }
        }

        if let preferred = try await reminderService.defaultList(), preferred.allowsModification {
            return .one(preferred)
        }
        if let fallback = available.first(where: \.isDefaultForNewReminders) ?? available.first {
            return .one(fallback)
        }
        throw ValidationFailure.noWritableContainer
    }

    /// Moves a previously chosen option to the front of the list.
    ///
    /// Deliberately only reorders. Auto-selecting from a remembered answer
    /// would mean acting on an inference the user never confirmed for *this*
    /// request, which is exactly what the ambiguity rule exists to prevent.
    func preferredFirst(_ options: [ClarificationOption], key: String) async -> [ClarificationOption] {
        guard let memory, options.count > 1 else { return options }

        let query = MemoryQuery(kinds: [.preference], subject: key, limit: 1, now: temporal.now)
        guard let remembered = try? await memory.recall(query).first?.memory,
              let index = options.firstIndex(where: {
                  $0.label.localizedCaseInsensitiveCompare(remembered.content) == .orderedSame
              })
        else { return options }

        var reordered = options
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    /// Exact title match first; only if none is found does it fall back to a
    /// contains match, so "Work" never quietly selects "Work Travel".
    private static func match<T>(name: String, in candidates: [(String, T)]) -> [T] {
        let exact = candidates.filter { $0.0.localizedCaseInsensitiveCompare(name) == .orderedSame }
        if !exact.isEmpty { return exact.map(\.1) }
        return candidates
            .filter { $0.0.localizedCaseInsensitiveContains(name) }
            .map(\.1)
    }

    // MARK: - Search windows

    /// The interval a query covers. Without a stated day, a search means today
    /// and a change means a wide window around today.
    func searchInterval(for query: EntityQuery) throws -> DateInterval {
        if let day = query.day {
            let dayInterval = try temporal.dayInterval(for: day)
            guard let time = query.time, case .clock(let hour, let minute) = time else {
                return dayInterval
            }
            // "my 2 PM meeting" narrows to an hour around the stated time.
            let anchor = try temporal.resolve(DateTimeSpec(day: day, time: .clock(hour: hour, minute: minute)))
            return DateInterval(
                start: anchor.date.addingTimeInterval(-1800),
                end: anchor.date.addingTimeInterval(1800)
            )
        }
        return try temporal.dayInterval(for: .today)
    }

    private func openEndedInterval() throws -> DateInterval {
        let start = try temporal.dayInterval(for: .daysFromToday(-preferences.openEndedSearchDaysBack)).start
        let end = try temporal.dayInterval(for: .daysFromToday(preferences.openEndedSearchDaysForward)).end
        return DateInterval(start: start, end: end)
    }

    // MARK: - Target resolution

    /// Turns a target description into concrete events.
    ///
    /// Conversational references are resolved from context; everything else is
    /// a real EventKit search. The result may be empty or hold several
    /// candidates — deciding what to do about that is the caller's job.
    func resolveEvents(_ query: EntityQuery, context: ValidationContext) async throws -> [CalendarEvent] {
        if let reference = query.reference {
            switch reference {
            case .resolved(let identifier):
                let found = try await calendarService.event(id: EventIdentifier(identifier))
                return found.map { [$0] } ?? []
            case .lastMentioned:
                return context.references.lastTouchedEvent.map { [$0] } ?? []
            case .ordinal(let position):
                let items = context.references.presentedEvents
                guard position >= 1, position <= items.count else { return [] }
                return [items[position - 1]]
            }
        }

        let interval = query.day == nil ? try openEndedInterval() : try searchInterval(for: query)
        var candidates = try await calendarService.events(in: interval, calendarIDs: nil)

        if let fragment = query.titleContains, !fragment.isEmpty {
            candidates = candidates.filter { $0.title.localizedCaseInsensitiveContains(fragment) }
        }
        if let name = query.containerName, !name.isEmpty {
            candidates = candidates.filter { $0.calendarTitle.localizedCaseInsensitiveContains(name) }
        }
        return candidates
    }

    func resolveReminders(_ query: EntityQuery, context: ValidationContext) async throws -> [Reminder] {
        if let reference = query.reference {
            switch reference {
            case .resolved(let identifier):
                let found = try await reminderService.reminder(id: ReminderIdentifier(identifier))
                return found.map { [$0] } ?? []
            case .lastMentioned:
                return context.references.lastTouchedReminder.map { [$0] } ?? []
            case .ordinal(let position):
                let items = context.references.presentedReminders
                guard position >= 1, position <= items.count else { return [] }
                return [items[position - 1]]
            }
        }

        let interval = query.day == nil ? nil : try searchInterval(for: query)
        var candidates = try await reminderService.reminders(
            dueIn: interval,
            listIDs: nil,
            filter: query.includeCompleted ? .all : .incompleteOnly
        )

        if let fragment = query.titleContains, !fragment.isEmpty {
            candidates = candidates.filter { $0.title.localizedCaseInsensitiveContains(fragment) }
        }
        if let name = query.containerName, !name.isEmpty {
            candidates = candidates.filter { $0.listTitle.localizedCaseInsensitiveContains(name) }
        }
        return candidates
    }

    // MARK: - Conflicts

    /// Existing events overlapping `interval`. All-day events are excluded:
    /// they do not block a timed commitment.
    func conflicts(for interval: DateInterval, excluding identifier: EventIdentifier? = nil) async throws -> [CalendarEvent] {
        let existing = try await calendarService.events(in: interval, calendarIDs: nil)
        return existing.filter { event in
            guard !event.isAllDay else { return false }
            guard event.id != identifier else { return false }
            return event.overlaps(interval)
        }
    }

    func conflictConfirmation(
        for title: String,
        at start: Date,
        conflicts: [CalendarEvent]
    ) -> ConfirmationRequest {
        let now = temporal.now
        let descriptions = conflicts.map { event in
            "\(event.title) from \(phrasing.time(event.start)) to \(phrasing.time(event.end))"
        }
        let list = Self.sentenceList(descriptions)
        let when = phrasing.dayAndTime(start, relativeTo: now)

        return ConfirmationRequest(
            reason: .conflict(existing: conflicts),
            summary: "Schedule \(title) \(when) despite \(list)",
            question: "You already have \(list). Do you still want \(title) \(when)?"
        )
    }

    // MARK: - Questions

    /// Presents the matches and asks which one, rather than picking.
    func disambiguation(
        events: [CalendarEvent],
        reminders: [Reminder],
        actionID: ActionID
    ) -> ClarificationRequest {
        let now = temporal.now
        var options: [ClarificationOption] = events.map {
            ClarificationOption(id: $0.id.rawValue, label: phrasing.describe($0, relativeTo: now))
        }
        options += reminders.map {
            ClarificationOption(id: $0.id.rawValue, label: phrasing.describe($0, relativeTo: now))
        }

        let noun = options.count == 2 ? "two" : "\(options.count)"
        let kind = events.isEmpty ? "reminders" : (reminders.isEmpty ? "events" : "items")

        return ClarificationRequest(
            subject: .whichRecord,
            question: "I found \(noun) matching \(kind). Which one?",
            options: options,
            actionID: actionID
        )
    }

    /// Restates a query in the words SARA will use to say it found nothing.
    func describe(_ query: EntityQuery, scope: EntityScope) -> String {
        let noun = scope == .reminders ? "a reminder" : "an event"
        var parts: [String] = []
        if let title = query.titleContains, !title.isEmpty {
            parts.append("called \(title)")
        }
        if let day = query.day, let resolved = try? temporal.resolveDay(day) {
            parts.append(phrasing.day(resolved, relativeTo: temporal.now))
        }
        return parts.isEmpty ? noun : "\(noun) \(parts.joined(separator: " "))"
    }

    /// Merges several confirmations into the single question SARA asks.
    func combine(_ requests: [ConfirmationRequest]) -> ConfirmationRequest {
        guard let first = requests.first else {
            return ConfirmationRequest(reason: .destructive, summary: "", question: "Should I go ahead?")
        }
        guard requests.count > 1 else { return first }

        let summary = requests.map(\.summary).joined(separator: ", and ")
        return ConfirmationRequest(
            reason: first.reason,
            summary: summary,
            question: "\(summary). Should I go ahead?"
        )
    }

    /// An absolute date expressed as a `DaySpec`, so a change can reuse the
    /// day a record already sits on.
    func dateSpec(of date: Date) -> DaySpec {
        let components = temporal.calendar.dateComponents([.year, .month, .day], from: date)
        return .explicit(year: components.year, month: components.month ?? 1, day: components.day ?? 1)
    }

    func clockComponents(of date: Date) -> (hour: Int, minute: Int) {
        let components = temporal.calendar.dateComponents([.hour, .minute], from: date)
        return (hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    static func sentenceList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and \(items[items.count - 1])"
        }
    }
}
