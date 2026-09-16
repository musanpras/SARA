import Foundation

/// SARA Core's entry point: one turn in, one answer out.
///
/// It owns the short-lived state a conversation needs — the question SARA is
/// waiting on, the plan that question is blocking, and what "it" refers to —
/// and drives the pipeline: interpret, validate, confirm, execute, verify,
/// respond. An actor because voice and text can both arrive at once.
public actor ConversationManager: RequestHandling {
    private let gateway: IntelligenceGateway
    private let validator: PlanValidator
    private let executor: PlanExecutor
    private let history: ActionHistory
    private let responses: ResponseGenerator
    private let dateProvider: DateProvider
    /// Local-first memory. Optional so the pipeline still runs when storage is
    /// unavailable — SARA forgets between launches rather than refusing to work.
    private let memory: (any MemoryStore)?
    private let answers = AnswerInterpreter()
    private let phrases = TemporalPhraseParser()

    /// The question SARA asked, and the plan it is holding until it is answered.
    private var pendingClarification: ClarificationRequest?
    private var pendingPlan: ActionPlan?
    private var pendingConfirmation: ConfirmationRequest?
    private var pendingExecutable: ExecutablePlan?

    private var references = ReferenceContext.empty
    private var recentTurns: [ConversationMessage] = []
    private let turnWindow = 8

    public init(
        gateway: IntelligenceGateway,
        validator: PlanValidator,
        executor: PlanExecutor,
        history: ActionHistory,
        responses: ResponseGenerator,
        dateProvider: DateProvider,
        memory: (any MemoryStore)? = nil
    ) {
        self.gateway = gateway
        self.validator = validator
        self.executor = executor
        self.history = history
        self.responses = responses
        self.dateProvider = dateProvider
        self.memory = memory
    }

    /// Reloads the recent conversation so references and context survive a
    /// relaunch. Call once at start-up.
    public func restoreSession() async {
        guard let memory else { return }
        recentTurns = (try? await memory.loadTurns(limit: turnWindow)) ?? []
    }

    // MARK: - RequestHandling

    public func handle(_ request: UserRequest) async -> AssistantTurn {
        await handle(request, progress: nil)
    }

    public func handle(
        _ request: UserRequest,
        progress: (any TurnProgressObserving)?
    ) async -> AssistantTurn {
        let text = request.normalizedText
        await remember(.user(text, at: request.timestamp))

        guard !text.isEmpty else {
            return await turn(SARAResponse(text: "I didn't catch that.", kind: .failure), state: .failed(message: "Empty request"))
        }

        // An explicit cancellation abandons whatever question is open and
        // returns to rest, before any attempt to read the reply as an answer.
        if pendingClarification != nil || pendingConfirmation != nil,
           answers.isCancellation(text) {
            clearPending()
            return await turn(SARAResponse(text: "Okay, I've cancelled that."), state: .idle)
        }

        if let answer = await handleConfirmationReply(text, request: request, progress: progress) {
            return answer
        }
        if let answer = await handleClarificationReply(text, request: request, progress: progress) {
            return answer
        }
        if let corrected = correctionPlan(for: text, request: request) {
            return await process(corrected, progress: progress)
        }

        let input = AIInput(request: request, context: currentContext())
        let result: AIResult
        do {
            result = try await gateway.interpret(input)
        } catch let error as AIProviderError {
            return await turn(responses.response(for: error), state: .failed(message: error.userMessage))
        } catch {
            return await turn(
                SARAResponse(text: "I couldn't work out what to do with that.", kind: .failure),
                state: .failed(message: "Interpretation failed")
            )
        }

        switch result {
        case .plan(let plan):
            return await process(plan, progress: progress)
        case .clarification(let request):
            pendingClarification = request
            return await turn(responses.response(for: request), state: .clarifying(question: request.question))
        case .conversation(let text):
            return await turn(SARAResponse(text: text), state: .idle)
        case .unsupported(let reason):
            return await turn(SARAResponse(text: reason, kind: .failure), state: .failed(message: reason))
        }
    }

    // MARK: - Pipeline

    private func process(
        _ plan: ActionPlan,
        progress: (any TurnProgressObserving)?
    ) async -> AssistantTurn {
        let context = ValidationContext(
            references: references,
            hasUndoableAction: await history.canUndo
        )

        switch await validator.validate(plan, context: context) {
        case .ready(let executable):
            clearPending()
            return await execute(executable, progress: progress)

        case .needsClarification(let question):
            pendingClarification = question
            pendingPlan = plan
            pendingConfirmation = nil
            pendingExecutable = nil
            return await turn(responses.response(for: question), state: .clarifying(question: question.question))

        case .needsConfirmation(let confirmation, let executable):
            pendingClarification = nil
            pendingPlan = plan
            pendingConfirmation = confirmation
            pendingExecutable = executable
            return await turn(responses.response(for: confirmation), state: .confirming(summary: confirmation.summary))

        case .rejected(let failure):
            clearPending()
            return await turn(responses.response(for: failure), state: .failed(message: failure.userMessage))
        }
    }

    private func execute(
        _ plan: ExecutablePlan,
        progress: (any TurnProgressObserving)?
    ) async -> AssistantTurn {
        // Announced before the first write, so the UI shows what is happening
        // rather than a generic wait — and only for work that actually runs.
        await progress?.executionDidBegin(plan.progressDescription)

        let report = await executor.execute(plan)
        let response = responses.response(for: report)

        // Only records SARA actually verified become referable.
        if !response.presentedEvents.isEmpty || !response.presentedReminders.isEmpty {
            references.present(events: response.presentedEvents, reminders: response.presentedReminders)
        }
        if let event = response.touchedEvent { references.recordTouch(event: event) }
        if let reminder = response.touchedReminder { references.recordTouch(reminder: reminder) }

        let state: AssistantState = report.allSucceeded
            ? .success(message: response.text)
            : .failed(message: response.text)
        return await turn(response, state: state)
    }

    // MARK: - Replies to SARA's own questions

    private func handleConfirmationReply(
        _ text: String,
        request: UserRequest,
        progress: (any TurnProgressObserving)?
    ) async -> AssistantTurn? {
        guard let confirmation = pendingConfirmation, let executable = pendingExecutable else { return nil }

        switch answers.agreement(in: text) {
        case .yes:
            clearPending()
            return await execute(executable, progress: progress)

        case .no:
            clearPending()
            return await turn(
                SARAResponse(text: "Alright, I've left it as it is."),
                state: .idle
            )

        case .unrelated:
            // "Actually, make that 5 PM" revises the pending plan instead of
            // answering it; anything else replaces it entirely.
            if let plan = pendingPlan, let revised = revise(plan, with: text) {
                clearPending()
                return await process(revised, progress: progress)
            }
            _ = confirmation
            clearPending()
            return nil
        }
    }

    private func handleClarificationReply(
        _ text: String,
        request: UserRequest,
        progress: (any TurnProgressObserving)?
    ) async -> AssistantTurn? {
        guard let question = pendingClarification else { return nil }

        if let plan = pendingPlan,
           let applied = answers.apply(answer: text, to: question, plan: plan) {
            await rememberChoice(applied.chosenOption, for: question)
            clearPending()
            return await process(applied.plan, progress: progress)
        }

        // Not an answer to the question — treat it as a new request rather than
        // forcing it into the slot.
        clearPending()
        return nil
    }

    // MARK: - Memory

    /// Remembers which container the user picked when several matched a name.
    ///
    /// Only container choices are stored: they recur, and the answer is a
    /// lasting preference. Picking one record out of three is a one-off and is
    /// deliberately not kept.
    private func rememberChoice(_ option: ClarificationOption?, for question: ClarificationRequest) async {
        guard question.subject == .whichContainer,
              let option,
              let key = question.memoryKey,
              let memory
        else { return }

        try? await memory.remember(
            MemoryRecord(
                kind: .preference,
                subject: key,
                content: option.label,
                createdAt: dateProvider.now
            )
        )
    }

    // MARK: - Corrections

    /// "Actually, make that 5 PM" applied to a plan that has not run yet.
    private func revise(_ plan: ActionPlan, with text: String) -> ActionPlan? {
        guard let replacement = correctionTemporal(in: text) else { return nil }
        guard let index = plan.actions.firstIndex(where: { $0.type == .calendarCreate || $0.type == .reminderCreate })
        else { return nil }

        let action = plan.actions[index]
        let payload: ActionPayload
        switch action.payload {
        case .calendarCreate(var parameters):
            parameters.when = DateTimeSpec(
                day: replacement.day ?? parameters.when?.day,
                time: replacement.time ?? parameters.when?.time ?? .unspecified
            )
            payload = .calendarCreate(parameters)
        case .reminderCreate(var parameters):
            parameters.due = DateTimeSpec(
                day: replacement.day ?? parameters.due?.day,
                time: replacement.time ?? parameters.due?.time ?? .unspecified
            )
            payload = .reminderCreate(parameters)
        default:
            return nil
        }

        var revised = plan
        revised.actions[index] = PlannedAction(id: action.id, payload: payload, dependsOn: action.dependsOn)
        revised.confirmationState = .notRequired
        return revised
    }

    /// "Actually, make that 5 PM" applied to something already done, which
    /// becomes an update to the record SARA last touched.
    private func correctionPlan(for text: String, request: UserRequest) -> ActionPlan? {
        guard let replacement = correctionTemporal(in: text) else { return nil }

        if references.lastTouchedEvent != nil {
            let action = PlannedAction(
                id: "correction",
                payload: .calendarUpdate(UpdateParameters(
                    target: EntityQuery(scope: .calendar, reference: .lastMentioned),
                    changes: EventChangeSpec(
                        when: DateTimeSpec(day: replacement.day, time: replacement.time ?? .unspecified)
                    )
                ))
            )
            return ActionPlan(requestID: request.id, actions: [action])
        }
        if references.lastTouchedReminder != nil {
            let action = PlannedAction(
                id: "correction",
                payload: .reminderUpdate(UpdateParameters(
                    target: EntityQuery(scope: .reminders, reference: .lastMentioned),
                    changes: ReminderChangeSpec(
                        due: DateTimeSpec(day: replacement.day, time: replacement.time ?? .unspecified)
                    )
                ))
            )
            return ActionPlan(requestID: request.id, actions: [action])
        }
        return nil
    }

    /// Recognises a correction and extracts the replacement day and/or time.
    private func correctionTemporal(in text: String) -> (day: DaySpec?, time: TimeSpec?)? {
        guard let prefix = text.firstMatch(
            of: /^\s*(actually|no|wait|sorry),?\s*(make\s+(it|that)\s+|change\s+(it|that)\s+to\s+|let'?s\s+make\s+it\s+)?/.ignoresCase()
        ), !prefix.range.isEmpty else { return nil }

        let remainder = String(text[prefix.range.upperBound...])
        let day = phrases.findDay(in: remainder)?.value
        let time = phrases.findTime(in: remainder)?.value
        guard day != nil || time != nil else { return nil }
        return (day, time)
    }

    // MARK: - State

    private func currentContext() -> InterpretationContext {
        InterpretationContext(
            recentTurns: recentTurns,
            pendingClarification: pendingClarification,
            pendingPlan: pendingPlan,
            pendingConfirmation: pendingConfirmation,
            references: references,
            now: dateProvider.now
        )
    }

    private func clearPending() {
        pendingClarification = nil
        pendingPlan = nil
        pendingConfirmation = nil
        pendingExecutable = nil
    }

    private func remember(_ message: ConversationMessage) async {
        recentTurns.append(message)
        if recentTurns.count > turnWindow {
            recentTurns.removeFirst(recentTurns.count - turnWindow)
        }

        // Awaited rather than detached, so turns are stored in the order they
        // were said. A storage failure is swallowed: the session is still
        // correct in memory, it simply will not survive a relaunch.
        try? await memory?.appendTurn(message)
    }

    private func turn(_ response: SARAResponse, state: AssistantState) async -> AssistantTurn {
        let message = ConversationMessage.sara(
            response.text,
            kind: response.kind,
            at: dateProvider.now
        )
        await remember(message)
        return AssistantTurn(messages: [message], state: state)
    }

    // MARK: - Introspection for the UI

    public var awaitingConfirmation: ConfirmationRequest? { pendingConfirmation }
    public var awaitingClarification: ClarificationRequest? { pendingClarification }
}
