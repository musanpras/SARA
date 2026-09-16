import Foundation

/// Opaque handle to an EventKit calendar.
///
/// EventKit types never leave the infrastructure layer, so the rest of SARA
/// refers to records through these string-backed identifiers instead.
public struct CalendarIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Opaque handle to an EventKit event.
public struct EventIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Opaque handle to an EventKit reminder.
public struct ReminderIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}
