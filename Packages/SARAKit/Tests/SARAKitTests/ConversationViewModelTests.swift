import Foundation
import Testing
import SARACore
import SARATesting
@testable import SARAKit

/// Records what it was asked and replies with a scripted turn.
private struct StubHandler: RequestHandling {
    let turn: AssistantTurn
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [UserRequest] = []
        var requests: [UserRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
        func record(_ request: UserRequest) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
        }
    }

    func handle(_ request: UserRequest) async -> AssistantTurn {
        recorder.record(request)
        return turn
    }
}

@MainActor
@Suite("ConversationViewModel")
struct ConversationViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_758_000_000)

    private func makeViewModel(
        state: AssistantState = .failed(message: "stub"),
        messages: [ConversationMessage]? = nil,
        speech: ScriptedSpeechRecognizer? = nil
    ) -> (ConversationViewModel, StubHandler.Recorder) {
        let clock = FixedDateProvider(now: now)
        let recorder = StubHandler.Recorder()
        let replies = messages ?? [.sara("stub reply", at: now)]
        let handler = StubHandler(
            turn: AssistantTurn(messages: replies, state: state),
            recorder: recorder
        )
        let viewModel = ConversationViewModel(
            handler: handler,
            speech: speech,
            dateProvider: clock
        )
        return (viewModel, recorder)
    }

    /// Lets the view model's detached listening task run to the point where it
    /// has consumed everything currently in the stream.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test("A submitted request lands in the transcript before SARA answers")
    func submitAppendsBothTurns() async {
        let (viewModel, recorder) = makeViewModel()

        await viewModel.submit(text: "  schedule gym  ", source: .text, confidence: nil)

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.normalizedText == "schedule gym")
        #expect(viewModel.transcript.messages.map(\.author) == [.user, .sara])
        #expect(viewModel.transcript.lastUserMessage?.text == "schedule gym")
    }

    @Test("Blank input is ignored entirely")
    func blankInputIsDropped() async {
        let (viewModel, recorder) = makeViewModel()

        await viewModel.submit(text: "   \n ", source: .text, confidence: nil)

        #expect(recorder.requests.isEmpty)
        #expect(viewModel.transcript.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test("Submitting the draft clears the field")
    func submitDraftClearsField() async {
        let (viewModel, _) = makeViewModel()
        viewModel.draftText = "remind me to call John"

        await viewModel.submitDraft()

        #expect(viewModel.draftText.isEmpty)
        #expect(viewModel.transcript.lastUserMessage?.text == "remind me to call John")
    }

    @Test("The handler's state becomes SARA's state")
    func stateFollowsHandler() async {
        let (viewModel, _) = makeViewModel(state: .clarifying(question: "When is it?"))

        await viewModel.submit(text: "schedule gym", source: .text, confidence: nil)

        #expect(viewModel.state == .clarifying(question: "When is it?"))
    }

    @Test("Push-to-talk enters and leaves the listening state")
    func listeningLifecycle() async {
        let recognizer = ScriptedSpeechRecognizer(finalTranscript: "schedule gym")
        let (viewModel, _) = makeViewModel(speech: recognizer)

        viewModel.beginListening()
        #expect(viewModel.state == .listening)
        #expect(!viewModel.canSubmit)

        viewModel.cancelListening()
        #expect(viewModel.state == .idle)
        #expect(viewModel.canSubmit)
    }

    @Test("Without a recogniser, push-to-talk does nothing rather than hanging")
    func noRecognizerCannotListen() {
        let (viewModel, _) = makeViewModel()

        viewModel.beginListening()
        #expect(viewModel.state == .idle)
        #expect(!viewModel.supportsVoice)
    }

    @Test("Partial speech is shown live but never submitted")
    func partialTranscriptIsNotSubmitted() async {
        let recognizer = ScriptedSpeechRecognizer(
            partials: ["sched", "schedule gym"],
            finalTranscript: "schedule gym tomorrow"
        )
        let (viewModel, recorder) = makeViewModel(speech: recognizer)

        viewModel.beginListening()
        await settle()

        #expect(viewModel.liveTranscript == "schedule gym")
        #expect(recorder.requests.isEmpty)
    }

    @Test("Releasing the button submits the final transcript with its confidence")
    func releaseSubmitsFinalTranscript() async {
        let recognizer = ScriptedSpeechRecognizer(
            partials: ["schedule"],
            finalTranscript: "schedule gym tomorrow at 4 pm",
            confidence: 0.88
        )
        let (viewModel, recorder) = makeViewModel(speech: recognizer)

        viewModel.beginListening()
        await settle()
        viewModel.endListening()
        await settle()

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.normalizedText == "schedule gym tomorrow at 4 pm")
        #expect(recorder.requests.first?.source == .voice)
        #expect(recorder.requests.first?.transcriptionConfidence == 0.88)
        #expect(viewModel.liveTranscript.isEmpty)
    }

    @Test("A recognition failure is surfaced, not swallowed")
    func recognitionFailureIsShown() async {
        let recognizer = ScriptedSpeechRecognizer(failure: .noSpeechDetected)
        let (viewModel, recorder) = makeViewModel(speech: recognizer)

        viewModel.beginListening()
        await settle()
        viewModel.endListening()
        await settle()

        #expect(recorder.requests.isEmpty)
        #expect(viewModel.transcript.lastSaraMessage?.text == "I didn't hear anything.")
        #expect(viewModel.transcript.lastSaraMessage?.kind == .failure)
    }

    @Test("Denied microphone access is reported through the same path")
    func deniedMicrophoneIsReported() async {
        let recognizer = ScriptedSpeechRecognizer(
            finalTranscript: "schedule gym",
            microphoneStatus: .denied
        )
        let (viewModel, recorder) = makeViewModel(speech: recognizer)

        viewModel.beginListening()
        await settle()

        #expect(recorder.requests.isEmpty)
        #expect(viewModel.transcript.lastSaraMessage?.text.contains("microphone") == true)
    }

    @Test("Voice source is carried through to the pipeline")
    func voiceSourceIsPreserved() async {
        let (viewModel, recorder) = makeViewModel()

        await viewModel.submit(text: "what's on my calendar", source: .voice, confidence: 0.91)

        #expect(recorder.requests.first?.source == .voice)
        #expect(recorder.requests.first?.transcriptionConfidence == 0.91)
    }
}
