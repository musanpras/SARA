import EventKit
import Foundation
import SARACore
import Testing
@testable import SARAKit

/// Parent suite for everything that touches the real EventKit database.
///
/// The child suites share one event store and one namespace sweep, so running
/// them concurrently made them delete each other's records mid-test. Nesting
/// them here serialises them, which is a property of the tests rather than of
/// how they happen to be invoked.
@Suite("EventKit", .serialized, .enabled(if: EventKitIntegrationSupport.isAuthorized))
struct EventKitIntegrationSuite {}

/// Shared setup for the suites that talk to the real EventKit database.
///
/// These run in the simulator against the actual store, which is the only way
/// to prove the mapping, the save semantics and the read-back verification that
/// the in-memory doubles can only imitate.
enum EventKitIntegrationSupport {
    /// Whether both permissions are already granted.
    ///
    /// The suites are skipped rather than failed when they are not, because an
    /// ungranted simulator is a missing precondition, not a broken build.
    /// Grant them with:
    ///   xcrun simctl privacy <device> grant calendar com.sara.assistant
    ///   xcrun simctl privacy <device> grant reminders com.sara.assistant
    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
            && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Shared services, so the whole run uses one `EKEventStore` per kind.
    ///
    /// Several stores live in one process race each other inside EventKit —
    /// running the suites in parallel with their own stores produced spurious
    /// `noWritableCalendar` failures — so every suite shares these.
    static let calendarService = EventKitCalendarService()
    static let reminderService = EventKitReminderService()

    /// Titles are namespaced so a failed run never deletes a real record and
    /// leftovers are always identifiable.
    static func title(_ name: String) -> String {
        "\(namespace)-\(UUID().uuidString.prefix(8))-\(name)"
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// A quiet, far-future window, so tests never collide with each other or
    /// with anything already in the simulator's calendar.
    static func slot(dayOffset: Int, hour: Int, minutes: Int = 60) -> (start: Date, end: Date) {
        let base = calendar.startOfDay(for: Date().addingTimeInterval(Double(dayOffset) * 86_400))
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        return (start, start.addingTimeInterval(Double(minutes) * 60))
    }
}

extension EventKitIntegrationSupport {
    /// Every record these tests create carries this in its title.
    static let namespace = "SARAIT"

    /// Removes anything left behind by an earlier run.
    ///
    /// Necessary because a failed test can exit before its own cleanup lands,
    /// and a stale record silently changes the result of a later conflict or
    /// search test. Only titles carrying the namespace are touched.
    static func sweep() async {
        let now = Date()
        let window = DateInterval(
            start: calendar.startOfDay(for: now.addingTimeInterval(-86_400)),
            duration: 90 * 86_400
        )

        if let events = try? await calendarService.events(in: window) {
            for event in events where event.title.contains(namespace) {
                try? await calendarService.delete(id: event.id, span: .futureEvents)
            }
        }
        if let reminders = try? await reminderService.reminders(
            dueIn: window,
            listIDs: nil,
            filter: .all
        ) {
            for reminder in reminders where reminder.title.contains(namespace) {
                try? await reminderService.delete(id: reminder.id)
            }
        }
    }

    /// Runs a test body with a clean store before and after.
    ///
    /// Cleanup is awaited on both the success and the failure path — a `defer`
    /// cannot await, and a detached task is not guaranteed to finish before the
    /// next test starts.
    /// Inherits the caller's isolation, so a `@MainActor` suite can use it
    /// without its body having to cross an isolation boundary.
    static func withCleanStore<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (IntegrationCleanup) async throws -> T
    ) async throws -> T {
        await sweep()
        let bin = IntegrationCleanup(
            calendarService: calendarService,
            reminderService: reminderService
        )
        do {
            let value = try await body(bin)
            await bin.run()
            await sweep()
            return value
        } catch {
            await bin.run()
            await sweep()
            throw error
        }
    }
}

/// Deletes everything a test created, whether or not the test passed.
actor IntegrationCleanup {
    private let calendarService: EventKitCalendarService
    private let reminderService: EventKitReminderService
    private var events: [EventIdentifier] = []
    private var reminders: [ReminderIdentifier] = []

    init(calendarService: EventKitCalendarService, reminderService: EventKitReminderService) {
        self.calendarService = calendarService
        self.reminderService = reminderService
    }

    func track(_ id: EventIdentifier) { events.append(id) }
    func track(_ id: ReminderIdentifier) { reminders.append(id) }

    func run() async {
        for id in events {
            try? await calendarService.delete(id: id, span: .futureEvents)
        }
        for id in reminders {
            try? await reminderService.delete(id: id)
        }
        events.removeAll()
        reminders.removeAll()
    }
}
