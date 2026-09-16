#if canImport(FoundationModels)
import FoundationModels

/// What the on-device model is asked to decide.
@available(iOS 26.0, macOS 26.0, *)
@Generable
enum ModelIntent {
    case createEvent
    case createReminder
    case searchCalendar
    case searchReminders
    case searchCalendarAndReminders
    case updateEvent
    case updateReminder
    case deleteEvent
    case deleteReminder
    case undoLastAction
    case smallTalk
    case somethingElse
}

/// The model's reading of one utterance.
///
/// Every temporal field is a *phrase in the user's own words* rather than a
/// date. The model says what was said; `TemporalPhraseParser` and
/// `TemporalEngine` decide what it means. That is what stops a language model
/// from inventing a Tuesday.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ExtractedCommand {
    @Guide(description: "What the user wants to do.")
    var intent: ModelIntent

    @Guide(description: "The name of the event or reminder, with no date or time words. For an update or delete, the name of the existing item. Leave empty if the user did not say one.")
    var title: String?

    @Guide(description: "The date and time exactly as the user said it, such as 'tomorrow at 4 pm' or 'next Friday'. Leave empty if the user gave none. Never guess a date.")
    var whenPhrase: String?

    @Guide(description: "For an update only: the new date or time as the user said it, such as '6 pm'.")
    var newWhenPhrase: String?

    @Guide(description: "How long it lasts, as the user said it, such as 'one hour' or '30 minutes'.")
    var durationPhrase: String?

    @Guide(description: "Any alert the user asked for, such as '30 minutes before'.")
    var alertPhrase: String?

    @Guide(description: "Any repeat the user asked for, such as 'every Monday' or 'every weekday'.")
    var recurrencePhrase: String?

    @Guide(description: "The calendar or reminders list the user named, if any.")
    var containerName: String?

    @Guide(description: "For small talk only: a short, calm reply of at most two sentences.")
    var reply: String?
}
#endif
