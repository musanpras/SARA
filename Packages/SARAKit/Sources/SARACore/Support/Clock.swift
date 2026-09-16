import Foundation

/// Injectable source of "now".
///
/// Every date-resolving component in SARA reads the current moment through this
/// protocol rather than calling `Date()` directly, so temporal behaviour can be
/// pinned in tests. The `TemporalEngine` depends on it heavily.
public protocol DateProvider: Sendable {
    var now: Date { get }
    /// Calendar carrying the user's locale and time zone.
    var calendar: Calendar { get }
}

/// Reads the real system clock and the user's current calendar configuration.
public struct SystemDateProvider: DateProvider {
    public init() {}

    public var now: Date { Date() }

    public var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

/// Deterministic clock for tests and previews.
public struct FixedDateProvider: DateProvider {
    public let now: Date
    public let calendar: Calendar

    public init(now: Date, calendar: Calendar = .gregorianUTC) {
        self.now = now
        self.calendar = calendar
    }
}

public extension Calendar {
    /// Gregorian calendar pinned to UTC — the baseline used by temporal tests.
    static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
}
