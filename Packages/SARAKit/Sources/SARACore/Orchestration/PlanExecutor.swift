import Foundation

/// Runs a validated plan wave by wave.
///
/// Independent actions in the same wave run concurrently; a wave only begins
/// once everything it depends on has succeeded. When a prerequisite fails, its
/// dependents are skipped and reported as skipped — never as done.
public struct PlanExecutor: Sendable {
    private let router: ToolRouter

    public init(router: ToolRouter) {
        self.router = router
    }

    public func execute(_ plan: ExecutablePlan) async -> ExecutionReport {
        var results: [ActionID: Result<ActionResult, ActionFailure>] = [:]

        for wave in plan.waves {
            let runnable = wave.compactMap { id -> ExecutableAction? in
                guard let action = plan.action(withID: id) else { return nil }

                // A dependency that failed or was skipped blocks this action.
                let blockers = action.dependsOn.filter { dependency in
                    guard let outcome = results[dependency] else { return true }
                    if case .failure = outcome { return true }
                    return false
                }
                guard blockers.isEmpty else {
                    results[id] = .failure(
                        .skipped(because: "it depended on a step that didn't succeed")
                    )
                    return nil
                }
                return action
            }

            guard !runnable.isEmpty else { continue }

            let waveResults = await withTaskGroup(
                of: (ActionID, Result<ActionResult, ActionFailure>).self
            ) { group in
                for action in runnable {
                    group.addTask {
                        do {
                            return (action.id, .success(try await router.execute(action.operation)))
                        } catch let failure as ActionFailure {
                            return (action.id, .failure(failure))
                        } catch {
                            return (action.id, .failure(ActionFailure(message: error.localizedDescription)))
                        }
                    }
                }

                var collected: [(ActionID, Result<ActionResult, ActionFailure>)] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }

            for (id, result) in waveResults {
                results[id] = result
            }
        }

        // Reported in plan order so the response reads in the order the user
        // asked for things.
        let entries = plan.actions.compactMap { action -> ExecutionReport.Entry? in
            guard let result = results[action.id] else { return nil }
            return ExecutionReport.Entry(id: action.id, result: result)
        }
        return ExecutionReport(entries: entries)
    }
}
