import Foundation

/// Layer 1: structural validation.
///
/// Pure and synchronous — it checks only what can be known without touching
/// EventKit, the clock or the conversation, so it runs first and cheaply.
public struct PlanSchemaValidator: Sendable {
    /// Plans below this confidence are refused; the caller asks the user to
    /// rephrase rather than acting on a guess.
    public let minimumConfidence: Double

    public init(minimumConfidence: Double = 0.35) {
        self.minimumConfidence = minimumConfidence
    }

    public func validate(_ plan: ActionPlan) throws {
        guard plan.schemaVersion == ActionPlan.currentSchemaVersion else {
            throw ValidationFailure.unsupportedSchemaVersion(plan.schemaVersion)
        }
        guard !plan.actions.isEmpty else {
            throw ValidationFailure.emptyPlan
        }
        guard (0.0...1.0).contains(plan.confidence) else {
            throw ValidationFailure.confidenceOutOfRange(plan.confidence)
        }
        guard plan.confidence >= minimumConfidence else {
            throw ValidationFailure.confidenceOutOfRange(plan.confidence)
        }

        var seen = Set<ActionID>()
        for action in plan.actions {
            guard seen.insert(action.id).inserted else {
                throw ValidationFailure.duplicateActionID(action.id)
            }
        }

        guard plan.executionWaves() != nil else {
            throw ValidationFailure.invalidDependencyGraph
        }

        for action in plan.actions {
            try validateAction(action)
        }
    }

    private func validateAction(_ action: PlannedAction) throws {
        // A mutating action with nothing identifying its target could hit the
        // wrong record, so it is refused outright rather than clarified.
        if !action.type.isReadOnly, let target = action.payload.target, target.isUnconstrained {
            throw ValidationFailure.unconstrainedTarget(action.type)
        }

        switch action.payload {
        case .calendarCreate(let parameters):
            if let duration = parameters.durationMinutes, duration <= 0 {
                throw ValidationFailure.nonPositiveDuration(duration)
            }
            if let recurrence = parameters.recurrence {
                do { try recurrence.validate() }
                catch let failure as RecurrenceRule.ValidationFailure {
                    throw ValidationFailure.invalidRecurrence(failure)
                }
            }

        case .calendarUpdate(let parameters):
            if let duration = parameters.changes.durationMinutes, duration <= 0 {
                throw ValidationFailure.nonPositiveDuration(duration)
            }

        case .undo(let parameters):
            guard parameters.steps == 1 else {
                throw ValidationFailure.unsupportedUndoDepth(parameters.steps)
            }

        case .calendarSearch, .calendarDelete, .reminderCreate,
             .reminderSearch, .reminderUpdate, .reminderDelete:
            break
        }
    }
}
