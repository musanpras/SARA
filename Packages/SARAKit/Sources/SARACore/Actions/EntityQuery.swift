import Foundation

/// How the user pointed at something: "it", "that", "the second one".
///
/// Resolution against real records happens in Swift, never in the model, so a
/// pronoun can never be turned straight into a deletion.
public enum EntityReference: Hashable, Sendable, Codable {
    /// "it", "that" — the thing most recently created, found or discussed.
    case lastMentioned
    /// "the second one" — 1-based position in the last presented list.
    case ordinal(Int)
    /// An identifier SARA itself resolved earlier in the turn.
    case resolved(String)
}

/// Which records a query is about.
public enum EntityScope: String, Hashable, Sendable, Codable {
    case calendar
    case reminders
    /// "What do I need to do tomorrow?" spans both, keeping the distinction.
    case both
}

/// A description of records to find, as stated by the user.
///
/// This is a *request* to search, not a result. `ValidationEngine` turns it
/// into candidates, and a destructive action may only proceed once exactly one
/// candidate remains and the user has confirmed it.
public struct EntityQuery: Hashable, Sendable, Codable {
    public var scope: EntityScope
    /// Case-insensitive fragment of the title, e.g. "gym".
    public var titleContains: String?
    /// The day the record falls on, when the user named one.
    public var day: DaySpec?
    /// A narrower time-of-day window within `day`, when the user gave one.
    public var time: TimeSpec?
    /// Calendar or list name as spoken, resolved to an identifier by Swift.
    public var containerName: String?
    /// A conversational pointer instead of a description.
    public var reference: EntityReference?
    public var includeCompleted: Bool

    public init(
        scope: EntityScope,
        titleContains: String? = nil,
        day: DaySpec? = nil,
        time: TimeSpec? = nil,
        containerName: String? = nil,
        reference: EntityReference? = nil,
        includeCompleted: Bool = false
    ) {
        self.scope = scope
        self.titleContains = titleContains
        self.day = day
        self.time = time
        self.containerName = containerName
        self.reference = reference
        self.includeCompleted = includeCompleted
    }

    /// True when the query says nothing at all about what to find. Such a query
    /// may never drive an update or a delete.
    public var isUnconstrained: Bool {
        titleContains == nil && day == nil && containerName == nil && reference == nil
    }
}
