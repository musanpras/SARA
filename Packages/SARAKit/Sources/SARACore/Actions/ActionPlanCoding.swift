import Foundation

/// Wire format for `ActionPayload` and `PlannedAction`.
///
/// Written by hand rather than synthesised so the JSON carries a readable
/// `type` discriminator (`"calendar.create"`). That keeps the schema stable
/// across Swift versions and legible to any provider that has to emit it.
extension ActionPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .calendarCreate:
            self = .calendarCreate(try container.decode(CalendarCreateParameters.self, forKey: .parameters))
        case .calendarSearch:
            self = .calendarSearch(try container.decode(SearchParameters.self, forKey: .parameters))
        case .calendarUpdate:
            self = .calendarUpdate(try container.decode(UpdateParameters<EventChangeSpec>.self, forKey: .parameters))
        case .calendarDelete:
            self = .calendarDelete(try container.decode(DeleteParameters.self, forKey: .parameters))
        case .reminderCreate:
            self = .reminderCreate(try container.decode(ReminderCreateParameters.self, forKey: .parameters))
        case .reminderSearch:
            self = .reminderSearch(try container.decode(SearchParameters.self, forKey: .parameters))
        case .reminderUpdate:
            self = .reminderUpdate(try container.decode(UpdateParameters<ReminderChangeSpec>.self, forKey: .parameters))
        case .reminderDelete:
            self = .reminderDelete(try container.decode(DeleteParameters.self, forKey: .parameters))
        case .undo:
            self = .undo(try container.decode(UndoParameters.self, forKey: .parameters))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        switch self {
        case .calendarCreate(let parameters): try container.encode(parameters, forKey: .parameters)
        case .calendarSearch(let parameters): try container.encode(parameters, forKey: .parameters)
        case .calendarUpdate(let parameters): try container.encode(parameters, forKey: .parameters)
        case .calendarDelete(let parameters): try container.encode(parameters, forKey: .parameters)
        case .reminderCreate(let parameters): try container.encode(parameters, forKey: .parameters)
        case .reminderSearch(let parameters): try container.encode(parameters, forKey: .parameters)
        case .reminderUpdate(let parameters): try container.encode(parameters, forKey: .parameters)
        case .reminderDelete(let parameters): try container.encode(parameters, forKey: .parameters)
        case .undo(let parameters): try container.encode(parameters, forKey: .parameters)
        }
    }
}

extension PlannedAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case dependsOn
        case type
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActionID.self, forKey: .id)
        dependsOn = try container.decodeIfPresent([ActionID].self, forKey: .dependsOn) ?? []
        payload = try ActionPayload(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !dependsOn.isEmpty {
            try container.encode(dependsOn, forKey: .dependsOn)
        }
        try payload.encode(to: encoder)
    }
}

extension ActionPlan: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case planID
        case requestID
        case actions
        case confidence
        case confirmationState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        planID = try container.decodeIfPresent(UUID.self, forKey: .planID) ?? UUID()
        requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID) ?? UUID()
        actions = try container.decode([PlannedAction].self, forKey: .actions)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        confirmationState = try container.decodeIfPresent(ConfirmationState.self, forKey: .confirmationState)
            ?? .notRequired
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(planID, forKey: .planID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(actions, forKey: .actions)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(confirmationState, forKey: .confirmationState)
    }
}
