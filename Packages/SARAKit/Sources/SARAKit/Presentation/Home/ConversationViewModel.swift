import Foundation
import Observation
import SARACore

/// Owns conversation presentation state and the voice session.
///
/// All reasoning, validation and execution sits behind `RequestHandling`; this
/// type sequences turns, drives push-to-talk, and speaks the answer. It holds
/// no business logic of its own.
@MainActor
@Observable
public final class ConversationViewModel {
    public private(set) var transcript = ConversationTranscript()
    public private(set) var state: AssistantState = .idle
    /// Live speech, shown while the user holds the button. Never acted on until
    /// the recogniser settles.
    public private(set) var liveTranscript: String = ""
    public var draftText: String = ""
    /// Whether SARA speaks its answers. Voice input stays available either way.
    /// Changed through `setSpeaksResponses` so the choice is persisted.
    public private(set) var speaksResponses: Bool

    private let handler: any RequestHandling
    private let speech: (any SpeechRecognizing)?
    private let voice: any VoiceOutputProvider
    private let dateProvider: any DateProvider
    private let memory: (any MemoryStore)?
    private var preferences: SARAPreferences

    private var listeningTask: Task<Void, Never>?
    private var speakingTask: Task<Void, Never>?

    public init(
        handler: any RequestHandling,
        speech: (any SpeechRecognizing)? = nil,
        voice: any VoiceOutputProvider = SilentVoiceOutputProvider(),
        dateProvider: any DateProvider = SystemDateProvider(),
        memory: (any MemoryStore)? = nil,
        preferences: SARAPreferences = .default,
        startupWarning: String? = nil
    ) {
        self.handler = handler
        self.speech = speech
        self.voice = voice
        self.dateProvider = dateProvider
        self.memory = memory
        self.preferences = preferences
        self.speaksResponses = preferences.speaksResponses

        // A storage problem is stated up front rather than discovered when
        // nothing turns out to have been remembered.
        if let startupWarning {
            transcript.append(.sara(startupWarning, kind: .failure, at: dateProvider.now))
        }
    }

    /// Turns spoken answers on or off, and remembers the choice.
    public func setSpeaksResponses(_ enabled: Bool) {
        speaksResponses = enabled
        preferences.speaksResponses = enabled
        if !enabled { cancelSpeaking() }

        guard let memory else { return }
        let updated = preferences
        Task { try? await memory.savePreferences(updated) }
    }

    public var canSubmit: Bool { state.acceptsInput }
    public var isListening: Bool { state == .listening }
    public var supportsVoice: Bool { speech != nil }

    // MARK: - Text

    public func submitDraft() async {
        let text = draftText
        draftText = ""
        await submit(text: text, source: .text, confidence: nil)
    }

    /// The one entry point shared by voice and text.
    public func submit(text: String, source: InputSource, confidence: Double?) async {
        let request = UserRequest(
            text: text,
            source: source,
            transcriptionConfidence: confidence,
            timestamp: dateProvider.now
        )
        guard !request.normalizedText.isEmpty else { return }

        transcript.append(.user(request.normalizedText, at: request.timestamp))
        transition(to: .processing)

        // The observer fires while `handle` is still running, so the UI can
        // distinguish thinking from writing to the calendar.
        let turn = await handler.handle(request, progress: makeProgressObserver())
        for message in turn.messages {
            transcript.append(message)
        }
        transition(to: turn.state)
        speakIfNeeded(turn)
    }

    // MARK: - Push to talk

    public func beginListening() {
        guard let speech, state.acceptsInput else { return }

        cancelSpeaking()
        liveTranscript = ""
        transition(to: .listening)

        listeningTask = Task { [weak self] in
            guard let self else { return }
            for await event in await speech.startListening() {
                if Task.isCancelled { break }
                await self.handle(event)
            }
        }
    }

    /// Called when the user lifts their finger: stop the audio and let the
    /// recogniser deliver a final transcript through the stream.
    public func endListening() {
        guard let speech, isListening else { return }
        Task { await speech.stopListening() }
    }

    /// Abandons the turn without submitting anything.
    public func cancelListening() {
        listeningTask?.cancel()
        listeningTask = nil
        liveTranscript = ""

        if let speech {
            Task { await speech.cancelListening() }
        }
        if isListening {
            transition(to: .idle)
        }
    }

    private func handle(_ event: SpeechEvent) async {
        switch event {
        case .partialTranscript(let text):
            liveTranscript = text

        case .finalTranscript(let text, let confidence):
            liveTranscript = ""
            listeningTask = nil
            // Leave `.listening` first: the state machine only allows
            // `.processing` to follow it, and `submit` makes that move.
            await submit(text: text, source: .voice, confidence: confidence)

        case .failed(let error):
            liveTranscript = ""
            listeningTask = nil
            transcript.append(.sara(error.userMessage, kind: .failure, at: dateProvider.now))
            transition(to: .failed(message: error.userMessage))
        }
    }

    /// Bridges the pipeline's progress callback back onto the main actor.
    ///
    /// `nonisolated(unsafe)` is not needed: the closure captures only `self`,
    /// and every touch of state happens inside the main-actor hop.
    private func makeProgressObserver() -> TurnProgressHandler {
        TurnProgressHandler { [weak self] description in
            await MainActor.run {
                self?.beginExecuting(description)
            }
        }
    }

    private func beginExecuting(_ description: String) {
        transition(to: .executing(description: description))
    }

    // MARK: - Speaking

    private func speakIfNeeded(_ turn: AssistantTurn) {
        guard speaksResponses else { return }
        let spoken = turn.messages
            .filter { $0.author == .sara }
            .map(\.text)
            .joined(separator: " ")
        guard !spoken.isEmpty else { return }

        speakingTask = Task { [voice] in
            await voice.speak(spoken)
        }
    }

    private func cancelSpeaking() {
        speakingTask?.cancel()
        speakingTask = nil
        Task { [voice] in await voice.stop() }
    }

    // MARK: - State

    /// Applies a state change, refusing transitions the state machine forbids.
    ///
    /// A rejected transition is a programming error rather than a user-facing
    /// one, so it is dropped rather than surfaced — the assertion catches it in
    /// debug builds.
    private func transition(to next: AssistantState) {
        guard state.canTransition(to: next) else {
            assertionFailure("Illegal transition \(state) -> \(next)")
            return
        }
        state = next
    }
}
