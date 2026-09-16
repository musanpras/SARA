import Foundation

/// Reports progress within a single turn.
///
/// A turn is not atomic from the user's point of view: interpreting and
/// validating a request is "thinking", but writing to EventKit is a distinct
/// step worth showing, especially when it follows a confirmation. The observer
/// is passed per turn rather than stored, so nothing has to be wired up in the
/// right order at start-up and a turn's progress cannot outlive it.
public protocol TurnProgressObserving: Sendable {
    /// Called once, immediately before validated work begins.
    ///
    /// `description` is a short present-tense phrase such as "Creating Gym".
    func executionDidBegin(_ description: String) async
}

/// Adapts a closure to `TurnProgressObserving`.
public struct TurnProgressHandler: TurnProgressObserving {
    private let onExecutionBegan: @Sendable (String) async -> Void

    public init(onExecutionBegan: @escaping @Sendable (String) async -> Void) {
        self.onExecutionBegan = onExecutionBegan
    }

    public func executionDidBegin(_ description: String) async {
        await onExecutionBegan(description)
    }
}
