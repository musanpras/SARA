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

    /// The microphone's role in a hands-free session. Alongside `state` (what
    /// SARA is doing in the conversation) this is the whole voice lifecycle;
    /// there are no separate `isListening` / `shouldListen` flags to drift out
    /// of sync. `.off` means manual push-to-talk only.
    public private(set) var voiceSessionMode: VoiceSessionMode = .off

    private let handler: any RequestHandling
    private let speech: (any SpeechRecognizing)?
    private let voice: any VoiceOutputProvider
    private let wakeWord: (any WakeWordDetecting)?
    private let dateProvider: any DateProvider
    private let memory: (any MemoryStore)?
    private let configuration: VoiceConfiguration
    private let policy = VoiceInteractionPolicy()
    private let wakeMatcher: WakeWordMatcher
    private var preferences: SARAPreferences

    private var listeningTask: Task<Void, Never>?
    private var speakingTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?

    public init(
        handler: any RequestHandling,
        speech: (any SpeechRecognizing)? = nil,
        voice: any VoiceOutputProvider = SilentVoiceOutputProvider(),
        wakeWord: (any WakeWordDetecting)? = nil,
        configuration: VoiceConfiguration = .default,
        dateProvider: any DateProvider = SystemDateProvider(),
        memory: (any MemoryStore)? = nil,
        preferences: SARAPreferences = .default,
        startupWarning: String? = nil
    ) {
        self.handler = handler
        self.speech = speech
        self.voice = voice
        self.wakeWord = wakeWord
        self.configuration = configuration
        self.wakeMatcher = WakeWordMatcher(phrase: configuration.wakeWord)
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
    /// Hands-free is offered only when there is both a recogniser to capture the
    /// command and a wake engine to start it, and the configuration allows it.
    public var supportsHandsFree: Bool {
        speech != nil && wakeWord != nil && configuration.wakeWordEnabled
    }
    /// Whether a hands-free session is currently running.
    public var isHandsFreeActive: Bool { voiceSessionMode.isActive }
    /// The configured wake phrase, for display in the UI.
    public var wakePhrase: String { configuration.wakeWord }

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
        if voiceSessionMode.isActive { voiceSessionMode = .processing }

        // The observer fires while `handle` is still running, so the UI can
        // distinguish thinking from writing to the calendar.
        let turn = await handler.handle(request, progress: makeProgressObserver())
        for message in turn.messages {
            transcript.append(message)
        }
        transition(to: turn.state)
        await completeTurn(turn)
    }

    /// Speaks the answer and, in a hands-free session, decides what the
    /// microphone does next: listen again for an answer, or return to the wake
    /// word. Speaking is awaited so the microphone never re-opens while SARA is
    /// still talking — it must not hear its own voice.
    private func completeTurn(_ turn: AssistantTurn) async {
        await speakIfNeeded(turn)
        guard voiceSessionMode.isActive else { return }

        switch policy.followUp(after: turn.state) {
        case .listenAgain:
            // SARA asked a question (clarification or confirmation): re-open the
            // microphone automatically, no button press.
            beginCommandCapture(followUp: true)
        case .returnToWakeWord:
            resumeWakeWord()
        }
    }

    // MARK: - Push to talk

    public func beginListening() {
        startCapture(endpointing: nil)
    }

    /// Opens the microphone for a hands-free command or follow-up answer, ending
    /// itself on silence via the recogniser's endpointing rather than a button.
    private func beginCommandCapture(followUp: Bool) {
        voiceSessionMode = .capturingCommand
        startCapture(endpointing: configuration.endpointing)
    }

    /// Shared capture entry. `endpointing` nil is push-to-talk (the caller ends
    /// it); non-nil lets the recogniser detect end-of-speech on its own.
    private func startCapture(endpointing: VoiceEndpointingOptions?) {
        guard let speech, state.acceptsInput else { return }

        cancelSpeaking()
        listeningTask?.cancel()
        liveTranscript = ""
        transition(to: .listening)

        listeningTask = Task { [weak self] in
            guard let self else { return }
            for await event in await speech.startListening(endpointing: endpointing) {
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
            // A wake phrase that bled into the command audio is stripped here so
            // the pipeline only ever sees the command itself.
            let command = wakeMatcher.stripping(from: text)
            guard !command.isEmpty else {
                // Heard only the wake word, or nothing usable. In a hands-free
                // session, quietly go back to waiting rather than erroring.
                if voiceSessionMode.isActive {
                    transition(to: .idle)
                    resumeWakeWord()
                } else {
                    transition(to: .idle)
                }
                return
            }
            // Leave `.listening` first: the state machine only allows
            // `.processing` to follow it, and `submit` makes that move.
            await submit(text: command, source: .voice, confidence: confidence)

        case .failed(let error):
            liveTranscript = ""
            listeningTask = nil
            transcript.append(.sara(error.userMessage, kind: .failure, at: dateProvider.now))
            transition(to: .failed(message: error.userMessage))
            // In a hands-free session a capture failure must not strand the
            // microphone: recover by returning to the wake word.
            if voiceSessionMode.isActive {
                if speaksResponses {
                    voiceSessionMode = .speaking
                    await voice.speak(error.userMessage)
                }
                resumeWakeWord()
            }
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

    /// Speaks SARA's reply and returns only when the utterance has finished.
    ///
    /// Awaited (rather than fired-and-forgotten) so a hands-free session can
    /// sequence the microphone after speech; `voice.stop()` resumes it early if
    /// the user interrupts, so awaiting never traps the turn.
    private func speakIfNeeded(_ turn: AssistantTurn) async {
        guard speaksResponses else { return }
        let spoken = turn.messages
            .filter { $0.author == .sara }
            .map(\.text)
            .joined(separator: " ")
        guard !spoken.isEmpty else { return }

        if voiceSessionMode.isActive { voiceSessionMode = .speaking }
        await voice.speak(spoken)
    }

    private func cancelSpeaking() {
        speakingTask?.cancel()
        speakingTask = nil
        Task { [voice] in await voice.stop() }
    }

    // MARK: - Hands-free session

    /// Starts a hands-free session: SARA waits for the wake word, then runs the
    /// whole listen -> process -> answer -> follow-up loop without any button.
    public func startHandsFree() {
        guard supportsHandsFree, voiceSessionMode == .off, let speech else { return }

        // Engage the session before the async permission hop, so the wake loop
        // (which requires an active session) can start once access is granted.
        voiceSessionMode = .idle

        // Prompt for microphone and speech access up front, once, so the wake
        // engine (which only reads authorization) has it granted.
        Task { [weak self] in
            guard let self else { return }
            if case .failure(let error) = await speech.requestAccess() {
                self.voiceSessionMode = .off
                self.transcript.append(.sara(error.userMessage, kind: .failure, at: self.dateProvider.now))
                return
            }
            self.resumeWakeWord()
        }
    }

    /// Ends the hands-free session and releases every audio resource.
    public func stopHandsFree() {
        voiceSessionMode = .off
        wakeTask?.cancel()
        wakeTask = nil
        listeningTask?.cancel()
        listeningTask = nil
        liveTranscript = ""
        if let wakeWord { Task { await wakeWord.stop() } }
        if let speech { Task { await speech.cancelListening() } }
        cancelSpeaking()
        if isListening || state.isProcessing { transition(to: .idle) }
    }

    /// Returns the microphone to wake-word listening between interactions.
    private func resumeWakeWord() {
        guard voiceSessionMode.isActive, let wakeWord else {
            voiceSessionMode = .off
            return
        }
        voiceSessionMode = .waitingForWakeWord
        if state != .idle, state.canTransition(to: .idle) { transition(to: .idle) }

        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            guard let self else { return }
            for await event in await wakeWord.start() {
                if Task.isCancelled { break }
                await self.handleWake(event)
            }
        }
    }

    private func handleWake(_ event: WakeWordEvent) async {
        guard voiceSessionMode == .waitingForWakeWord else { return }
        switch event {
        case .detected(let trailingCommand):
            wakeTask = nil
            if let trailingCommand, !trailingCommand.isEmpty {
                // The user ran the command into the wake phrase ("Hey SARA,
                // what's next?"): use those words instead of re-opening the mic.
                await submit(text: trailingCommand, source: .voice, confidence: nil)
            } else {
                beginCommandCapture(followUp: false)
            }
        case .failed(let error):
            wakeTask = nil
            voiceSessionMode = .off
            transcript.append(.sara(error.userMessage, kind: .failure, at: dateProvider.now))
        }
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
