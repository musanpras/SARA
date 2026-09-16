import Foundation

/// A calendar the user can write to, described without EventKit types.
public struct CalendarDescriptor: Identifiable, Hashable, Sendable {
    public let id: CalendarIdentifier
    public let title: String
    /// Source name, e.g. "iCloud" or "Gmail". Used to disambiguate calendars
    /// that share a title across accounts.
    public let sourceTitle: String
    public let allowsModification: Bool
    public let isDefaultForNewEvents: Bool

    public init(
        id: CalendarIdentifier,
        title: String,
        sourceTitle: String,
        allowsModification: Bool,
        isDefaultForNewEvents: Bool
    ) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.allowsModification = allowsModification
        self.isDefaultForNewEvents = isDefaultForNewEvents
    }

    /// Title qualified by source, for use when two calendars share a name.
    public var qualifiedTitle: String {
        sourceTitle.isEmpty ? title : "\(title) (\(sourceTitle))"
    }
}
