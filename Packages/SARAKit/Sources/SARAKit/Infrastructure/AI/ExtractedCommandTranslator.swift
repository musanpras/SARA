import Foundation
import SARACore

#if canImport(FoundationModels)
import FoundationModels

/// Maps the model's generated type onto SARA's provider-neutral slots.
///
/// The only Foundation Models-specific code in the intelligence path; every
/// provider converges on `ExtractedSlots` and shares one plan builder.
@available(iOS 26.0, macOS 26.0, *)
struct ExtractedCommandTranslator {
    private let builder = SlotPlanBuilder()

    func translate(_ command: ExtractedCommand, for request: UserRequest) -> AIResult? {
        let slots = ExtractedSlots(
            intent: Self.intent(command.intent),
            title: command.title,
            whenPhrase: command.whenPhrase,
            newWhenPhrase: command.newWhenPhrase,
            durationPhrase: command.durationPhrase,
            alertPhrase: command.alertPhrase,
            recurrencePhrase: command.recurrencePhrase,
            containerName: command.containerName,
            reply: command.reply
        )
        return builder.build(slots, for: request)
    }

    private static func intent(_ intent: ModelIntent) -> ExtractedIntent {
        switch intent {
        case .createEvent: .createEvent
        case .createReminder: .createReminder
        case .searchCalendar: .searchCalendar
        case .searchReminders: .searchReminders
        case .searchCalendarAndReminders: .searchCalendarAndReminders
        case .updateEvent: .updateEvent
        case .updateReminder: .updateReminder
        case .deleteEvent: .deleteEvent
        case .deleteReminder: .deleteReminder
        case .undoLastAction: .undoLastAction
        case .smallTalk: .smallTalk
        case .somethingElse: .unsupported
        }
    }
}
#endif
