import Foundation

/// Reads short replies to SARA's own questions.
///
/// Answers like "yes", "the second one" or "4 PM" are only meaningful next to
/// the question that prompted them, so they are handled here rather than being
/// sent back through general interpretation.
struct AnswerInterpreter: Sendable {
    private let phrases = TemporalPhraseParser()

    enum Agreement {
        case yes
        case no
        /// Not an answer to the question — treat it as a new request.
        case unrelated
    }

    func agreement(in text: String) -> Agreement {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        if trimmed.wholeMatch(of: /(yes|yeah|yep|yup|sure|ok|okay|go ahead|do it|please do|confirm|correct|that'?s right|affirmative)/.ignoresCase()) != nil {
            return .yes
        }
        if trimmed.wholeMatch(of: /(no|nope|nah|cancel|stop|don'?t|do not|never mind|nevermind|forget it|leave it)/.ignoresCase()) != nil {
            return .no
        }
        return .unrelated
    }

    /// The result of slotting an answer into a waiting plan.
    struct Applied {
        let plan: ActionPlan
        /// Set when the user picked from a list, so the caller can remember it.
        let chosenOption: ClarificationOption?
    }

    /// Applies an answer to the plan the question was blocking.
    ///
    /// Returns `nil` when the reply does not answer the question, so the caller
    /// can treat it as a fresh command instead of forcing it into the slot.
    func apply(
        answer: String,
        to request: ClarificationRequest,
        plan: ActionPlan
    ) -> Applied? {
        guard let actionID = request.actionID ?? plan.actions.first?.id,
              let index = plan.actions.firstIndex(where: { $0.id == actionID })
        else { return nil }

        let action = plan.actions[index]
        let chosen = request.options.isEmpty ? nil : choose(from: request.options, answer: answer)
        guard let payload = updated(action.payload, with: answer, for: request, chosen: chosen)
        else { return nil }

        var updatedPlan = plan
        updatedPlan.actions[index] = PlannedAction(
            id: action.id,
            payload: payload,
            dependsOn: action.dependsOn
        )
        return Applied(plan: updatedPlan, chosenOption: chosen)
    }

    private func updated(
        _ payload: ActionPayload,
        with answer: String,
        for request: ClarificationRequest,
        chosen: ClarificationOption?
    ) -> ActionPayload? {
        switch request.subject {
        case .eventTitle:
            guard case .calendarCreate(var parameters) = payload else { return nil }
            let title = LocalCommandInterpreter.cleanTitle(answer)
            guard !title.isEmpty else { return nil }
            parameters.title = title
            return .calendarCreate(parameters)

        case .reminderTitle:
            guard case .reminderCreate(var parameters) = payload else { return nil }
            let title = LocalCommandInterpreter.cleanTitle(answer)
            guard !title.isEmpty else { return nil }
            parameters.title = title
            return .reminderCreate(parameters)

        case .eventDate, .whichDate:
            guard let day = phrases.findDay(in: answer)?.value else { return nil }
            guard case .calendarCreate(var parameters) = payload else { return nil }
            let time = phrases.findTime(in: answer)?.value ?? parameters.when?.time ?? .unspecified
            parameters.when = DateTimeSpec(day: day, time: time)
            return .calendarCreate(parameters)

        case .eventTime:
            guard let time = phrases.findTime(in: answer)?.value else { return nil }
            guard case .calendarCreate(var parameters) = payload else { return nil }
            parameters.when = DateTimeSpec(day: parameters.when?.day, time: time)
            return .calendarCreate(parameters)

        case .reminderDueDate:
            guard case .reminderCreate(var parameters) = payload else { return nil }
            let day = phrases.findDay(in: answer)?.value ?? parameters.due?.day
            let time = phrases.findTime(in: answer)?.value ?? parameters.due?.time ?? .unspecified
            guard day != nil else { return nil }
            parameters.due = DateTimeSpec(day: day, time: time)
            return .reminderCreate(parameters)

        case .whichRecord:
            guard let option = chosen else { return nil }
            // The chosen record is pinned by identifier, so the second search
            // cannot land on a different one.
            return retarget(payload, to: EntityReference.resolved(option.id))

        case .whichContainer:
            guard let option = chosen else { return nil }
            return setContainer(payload, to: option)
        }
    }

    /// Matches "the second one", a spoken ordinal, or part of the label itself.
    private func choose(from options: [ClarificationOption], answer: String) -> ClarificationOption? {
        guard !options.isEmpty else { return nil }

        if let match = answer.firstMatch(of: /\b(first|second|third|fourth|fifth|last)\b/.ignoresCase()) {
            let word = String(match.1).lowercased()
            if word == "last" { return options.last }
            if let ordinal = TemporalPhraseParser.ordinals[word], ordinal >= 1, ordinal <= options.count {
                return options[ordinal - 1]
            }
            return nil
        }
        if let match = answer.firstMatch(of: /\b(\d)\b/) {
            if let index = Int(match.1), index >= 1, index <= options.count {
                return options[index - 1]
            }
            return nil
        }

        let cleaned = answer.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        guard cleaned.count >= 3 else { return nil }
        let matches = options.filter { $0.label.localizedCaseInsensitiveContains(cleaned) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func retarget(_ payload: ActionPayload, to reference: EntityReference) -> ActionPayload? {
        func pin(_ query: EntityQuery) -> EntityQuery {
            var copy = query
            copy.reference = reference
            copy.titleContains = nil
            copy.day = nil
            copy.time = nil
            return copy
        }

        switch payload {
        case .calendarDelete(var parameters):
            parameters.target = pin(parameters.target)
            return .calendarDelete(parameters)
        case .reminderDelete(var parameters):
            parameters.target = pin(parameters.target)
            return .reminderDelete(parameters)
        case .calendarUpdate(var parameters):
            parameters.target = pin(parameters.target)
            return .calendarUpdate(parameters)
        case .reminderUpdate(var parameters):
            parameters.target = pin(parameters.target)
            return .reminderUpdate(parameters)
        default:
            return nil
        }
    }

    /// Pins the chosen container by identifier.
    ///
    /// Writing the *name* back would re-ask the same question, because the name
    /// is exactly what was ambiguous. The option's identifier is unambiguous,
    /// so it is what gets stored — the same reasoning as pinning a record.
    private func setContainer(_ payload: ActionPayload, to option: ClarificationOption) -> ActionPayload? {
        switch payload {
        case .calendarCreate(var parameters):
            parameters.calendarID = option.id
            parameters.calendarName = nil
            return .calendarCreate(parameters)
        case .reminderCreate(var parameters):
            parameters.listID = option.id
            parameters.listName = nil
            return .reminderCreate(parameters)
        case .calendarUpdate(var parameters):
            parameters.changes.calendarID = option.id
            parameters.changes.calendarName = nil
            return .calendarUpdate(parameters)
        case .reminderUpdate(var parameters):
            parameters.changes.listID = option.id
            parameters.changes.listName = nil
            return .reminderUpdate(parameters)
        default:
            return nil
        }
    }
}
