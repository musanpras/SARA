import Foundation
import Testing
@testable import SARACore

@Suite("ActionPlan")
struct ActionPlanTests {
    private let requestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func plan(_ actions: [PlannedAction]) -> ActionPlan {
        ActionPlan(requestID: requestID, actions: actions)
    }

    private var createGym: PlannedAction {
        PlannedAction(
            id: "create-event",
            payload: .calendarCreate(
                CalendarCreateParameters(
                    title: "Gym",
                    when: DateTimeSpec(day: .tomorrow, time: .clock(hour: 16, minute: 0)),
                    durationMinutes: 60
                )
            )
        )
    }

    private var deleteGym: PlannedAction {
        PlannedAction(
            id: "delete-event",
            payload: .calendarDelete(
                DeleteParameters(target: EntityQuery(scope: .calendar, titleContains: "Gym", day: .tomorrow))
            )
        )
    }

    // MARK: - Classification

    @Test("Deletes are destructive, searches are read-only")
    func classification() {
        #expect(ActionType.calendarDelete.isDestructive)
        #expect(ActionType.reminderDelete.isDestructive)
        #expect(!ActionType.calendarUpdate.isDestructive)
        #expect(ActionType.calendarSearch.isReadOnly)
        #expect(!ActionType.calendarCreate.isReadOnly)

        #expect(plan([deleteGym]).containsDestructiveAction)
        #expect(!plan([createGym]).containsDestructiveAction)
    }

    @Test("A plan of only searches is read-only; an empty plan is not")
    func readOnlyPlans() {
        let search = PlannedAction(
            id: "search",
            payload: .calendarSearch(SearchParameters(query: EntityQuery(scope: .calendar, day: .tomorrow)))
        )
        #expect(plan([search]).isReadOnly)
        #expect(!plan([search, createGym]).isReadOnly)
        #expect(!plan([]).isReadOnly)
        #expect(plan([]).isEmpty)
    }

    @Test("A payload exposes its target query for the actions that have one")
    func payloadTargets() {
        #expect(deleteGym.payload.target?.titleContains == "Gym")
        #expect(createGym.payload.target == nil)
    }

    // MARK: - Dependency graph

    @Test("Independent actions share one wave")
    func independentActionsRunTogether() throws {
        let reminder = PlannedAction(
            id: "create-reminder",
            payload: .reminderCreate(ReminderCreateParameters(title: "Call John"))
        )
        let waves = try #require(plan([createGym, reminder]).executionWaves())

        #expect(waves.count == 1)
        #expect(waves[0].count == 2)
    }

    @Test("A dependent action waits for its prerequisite")
    func dependentActionsAreSequenced() throws {
        let reminder = PlannedAction(
            id: "create-reminder",
            payload: .reminderCreate(ReminderCreateParameters(title: "Gym in 30 minutes")),
            dependsOn: ["create-event"]
        )
        let waves = try #require(plan([reminder, createGym]).executionWaves())

        #expect(waves.count == 2)
        #expect(waves[0].map(\.id) == ["create-event"])
        #expect(waves[1].map(\.id) == ["create-reminder"])
    }

    @Test("A cyclic graph yields no ordering rather than a partial one")
    func cycleIsRejected() {
        let first = PlannedAction(
            id: "a",
            payload: .reminderCreate(ReminderCreateParameters(title: "A")),
            dependsOn: ["b"]
        )
        let second = PlannedAction(
            id: "b",
            payload: .reminderCreate(ReminderCreateParameters(title: "B")),
            dependsOn: ["a"]
        )
        #expect(plan([first, second]).executionWaves() == nil)
    }

    @Test("A dependency on an unknown action is rejected")
    func danglingDependency() {
        let orphan = PlannedAction(
            id: "a",
            payload: .reminderCreate(ReminderCreateParameters(title: "A")),
            dependsOn: ["does-not-exist"]
        )
        #expect(plan([orphan]).executionWaves() == nil)
    }

    // MARK: - Wire format

    @Test("Actions decode from the documented JSON shape")
    func decodesFromJSON() throws {
        let json = """
        {
          "schemaVersion": 1,
          "requestID": "11111111-1111-1111-1111-111111111111",
          "confidence": 0.9,
          "actions": [
            {
              "id": "create-event",
              "type": "calendar.create",
              "parameters": {
                "title": "Gym",
                "when": { "day": { "tomorrow": {} }, "time": { "clock": { "hour": 16, "minute": 0 } } },
                "durationMinutes": 60,
                "isAllDay": false,
                "alertMinutesBefore": [30]
              }
            },
            {
              "id": "create-reminder",
              "type": "reminder.create",
              "dependsOn": ["create-event"],
              "parameters": { "title": "Leave for the gym", "alertMinutesBefore": [] }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.requestID == requestID)
        #expect(decoded.confidence == 0.9)
        #expect(decoded.actions.count == 2)
        #expect(decoded.confirmationState == .notRequired)

        guard case .calendarCreate(let parameters) = decoded.actions[0].payload else {
            Issue.record("Expected a calendar.create payload")
            return
        }
        #expect(parameters.title == "Gym")
        #expect(parameters.durationMinutes == 60)
        #expect(parameters.alertMinutesBefore == [30])
        #expect(parameters.when?.day == .tomorrow)
        #expect(parameters.when?.time == .clock(hour: 16, minute: 0))
        #expect(decoded.actions[1].dependsOn == ["create-event"])
    }

    @Test("An unknown action type is rejected rather than ignored")
    func unknownActionTypeRejected() {
        let json = """
        {
          "schemaVersion": 1,
          "actions": [{ "id": "a", "type": "calendar.explode", "parameters": {} }]
        }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ActionPlan.self, from: Data(json.utf8))
        }
    }

    @Test("A plan survives an encode/decode round trip")
    func roundTrip() throws {
        let original = ActionPlan(
            requestID: requestID,
            actions: [createGym, deleteGym],
            confidence: 0.75,
            confirmationState: .pending
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionPlan.self, from: data)

        #expect(decoded == original)
    }
}
