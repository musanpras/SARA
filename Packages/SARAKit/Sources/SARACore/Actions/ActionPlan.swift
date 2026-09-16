import Foundation

/// Stable name for an action, used by dependency edges.
public struct ActionID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The operations SARA can currently perform.
///
/// Adding a capability means adding a case plus a payload and a tool handler —
/// nothing else in the pipeline changes shape.
public enum ActionType: String, Hashable, Sendable, Codable, CaseIterable {
    case calendarCreate = "calendar.create"
    case calendarSearch = "calendar.search"
    case calendarUpdate = "calendar.update"
    case calendarDelete = "calendar.delete"
    case reminderCreate = "reminder.create"
    case reminderSearch = "reminder.search"
    case reminderUpdate = "reminder.update"
    case reminderDelete = "reminder.delete"
    case undo

    /// Deletions always require explicit confirmation.
    public var isDestructive: Bool {
        self == .calendarDelete || self == .reminderDelete
    }

    /// Reads never mutate anything, so they skip confirmation and conflict checks.
    public var isReadOnly: Bool {
        self == .calendarSearch || self == .reminderSearch
    }
}

/// The typed payload for one action.
public enum ActionPayload: Hashable, Sendable {
    case calendarCreate(CalendarCreateParameters)
    case calendarSearch(SearchParameters)
    case calendarUpdate(UpdateParameters<EventChangeSpec>)
    case calendarDelete(DeleteParameters)
    case reminderCreate(ReminderCreateParameters)
    case reminderSearch(SearchParameters)
    case reminderUpdate(UpdateParameters<ReminderChangeSpec>)
    case reminderDelete(DeleteParameters)
    case undo(UndoParameters)

    public var type: ActionType {
        switch self {
        case .calendarCreate: .calendarCreate
        case .calendarSearch: .calendarSearch
        case .calendarUpdate: .calendarUpdate
        case .calendarDelete: .calendarDelete
        case .reminderCreate: .reminderCreate
        case .reminderSearch: .reminderSearch
        case .reminderUpdate: .reminderUpdate
        case .reminderDelete: .reminderDelete
        case .undo: .undo
        }
    }

    /// The target query, for the actions that have one.
    public var target: EntityQuery? {
        switch self {
        case .calendarSearch(let parameters), .reminderSearch(let parameters):
            parameters.query
        case .calendarUpdate(let parameters):
            parameters.target
        case .reminderUpdate(let parameters):
            parameters.target
        case .calendarDelete(let parameters), .reminderDelete(let parameters):
            parameters.target
        case .calendarCreate, .reminderCreate, .undo:
            nil
        }
    }
}

/// One step in a plan.
public struct PlannedAction: Hashable, Sendable, Identifiable {
    public let id: ActionID
    public let payload: ActionPayload
    /// Actions that must succeed before this one may run.
    public let dependsOn: [ActionID]

    public init(id: ActionID, payload: ActionPayload, dependsOn: [ActionID] = []) {
        self.id = id
        self.payload = payload
        self.dependsOn = dependsOn
    }

    public var type: ActionType { payload.type }
}

/// Whether the user has agreed to a plan that needs agreeing to.
public enum ConfirmationState: String, Hashable, Sendable, Codable {
    case notRequired
    case pending
    case confirmed
    case declined
}

/// A versioned, typed unit of work.
///
/// This is the only thing the intelligence layer may produce, and the only
/// thing the execution layer will accept. Free-form model text never reaches
/// EventKit.
public struct ActionPlan: Hashable, Sendable {
    /// Bumped whenever the wire shape changes incompatibly.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let planID: UUID
    /// Ties the plan back to the utterance that produced it.
    public let requestID: UUID
    public var actions: [PlannedAction]
    /// The interpreter's confidence, 0...1. Low confidence routes to a
    /// clarification rather than to execution.
    public var confidence: Double
    public var confirmationState: ConfirmationState

    public init(
        schemaVersion: Int = ActionPlan.currentSchemaVersion,
        planID: UUID = UUID(),
        requestID: UUID,
        actions: [PlannedAction],
        confidence: Double = 1.0,
        confirmationState: ConfirmationState = .notRequired
    ) {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.requestID = requestID
        self.actions = actions
        self.confidence = confidence
        self.confirmationState = confirmationState
    }

    public var isEmpty: Bool { actions.isEmpty }

    public var containsDestructiveAction: Bool {
        actions.contains { $0.type.isDestructive }
    }

    public var isReadOnly: Bool {
        !actions.isEmpty && actions.allSatisfy { $0.type.isReadOnly }
    }

    public func action(withID id: ActionID) -> PlannedAction? {
        actions.first { $0.id == id }
    }

    /// Actions in dependency order, grouped into waves that may run together.
    ///
    /// Returns `nil` when the graph is cyclic or refers to unknown actions;
    /// callers treat that as an invalid plan rather than executing part of it.
    public func executionWaves() -> [[PlannedAction]]? {
        let known = Set(actions.map(\.id))
        guard actions.allSatisfy({ $0.dependsOn.allSatisfy(known.contains) }) else { return nil }

        var remaining = actions
        var settled = Set<ActionID>()
        var waves: [[PlannedAction]] = []

        while !remaining.isEmpty {
            let ready = remaining.filter { $0.dependsOn.allSatisfy(settled.contains) }
            guard !ready.isEmpty else { return nil } // cycle
            waves.append(ready)
            settled.formUnion(ready.map(\.id))
            let readyIDs = Set(ready.map(\.id))
            remaining.removeAll { readyIDs.contains($0.id) }
        }
        return waves
    }
}
