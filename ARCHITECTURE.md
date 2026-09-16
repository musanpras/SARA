# SARA architecture

## The principle everything follows

> The model decides *what* should happen. Swift decides *how* it happens.

A language model never touches EventKit, never produces a `Date`, and never
decides that an action succeeded. It produces a typed `ActionPlan`; Swift
validates it, executes it, and reads the result back before SARA says a word.

## The pipeline

```
utterance (voice or text)
  → ConversationManager        pending question? correction? new request?
  → IntelligenceGateway        which provider, and what may it see
      → AIRouter               deterministic choice
      → PrivacyGateway         minimise and redact for off-device providers
      → AIProvider             LocalCommandInterpreter | AppleFoundationModel
  → MemoryStore                preferences, session, remembered choices
  → ActionPlan v1              typed, versioned, no free text
  → PlanSchemaValidator        structure, graph, confidence
  → PlanValidator              semantics, targets, permissions, conflicts
  → ExecutablePlan             every parameter resolved and verified
  → PlanExecutor               waves; dependents wait, failures skip
      → ToolRouter → CalendarTool / ReminderTool → EventKit
  → ExecutionReport            per-action success or failure
       ↑ TurnProgressObserving  announces execution starting, for the UI
  → ResponseGenerator          adaptive wording
  → transcript + AVSpeechSynthesizer
```

Every stage is independently testable, and most are pure functions.

## Decisions worth knowing

**Two modules, not one.** `SARACore` imports nothing but Foundation. That is
what lets the whole domain — plans, validation, temporal reasoning, response
generation — be tested on the host in milliseconds instead of through a
simulator. `SARAKit` holds EventKit, Speech, Foundation Models and SwiftUI.

**The model is never asked for a date.** Providers return the user's own words
("tomorrow at 4 pm") as phrases. `TemporalPhraseParser` structures them and
`TemporalEngine` resolves them against the user's calendar and time zone. A
model that hallucinates a date has nowhere to put it. This is also why swapping
Apple's model for a cloud one cannot change which day an event lands on.

**A deterministic parser sits in front of the model.** Most commands — create,
search, move, delete, undo — follow regular enough phrasing that
`LocalCommandInterpreter` handles them with no model at all: no latency, no
cost, works offline. The router escalates only what it declines.

**Ambiguity is surfaced, not resolved.** "Next Friday" has two defensible
readings, so `TemporalEngine` refuses and returns both candidates. Two calendars
named "Home" produce a question rather than a coin flip. Three matching meetings
produce a list.

**Deletion is never inferred.** A mutating action whose target query says
nothing identifying is rejected outright by the schema validator. Deletions
always require explicit confirmation, and a pronoun is resolved to a concrete
record in Swift before it reaches a tool.

**Writes are verified, not assumed.** Every mutating `CalendarService` and
`ReminderService` call re-reads the record and returns it. A caller holding a
value has proof. `ExecutionReport` distinguishes success, failure and skipped,
so partial success is reported as partial.

**Undo covers only what reverses cleanly.** Creating and updating are recorded
with their inverse. Deleting is not: re-creating the record would mint a new
identifier and lose series membership, so SARA says it cannot undo a deletion
rather than producing a lookalike.

**Memory is local-first and deliberately partitioned.** `MemoryStore` keeps
four separate things: preferences the user chose, what SARA did (so it can be
undone after a relaunch), what was said (so a conversation resumes), and
memories worth recalling later. EventKit records are never copied into any of
them. SwiftData backs it; the same implementation runs memory-only when the
database cannot be opened, and the user is told rather than left wondering why
nothing was remembered.

**Retrieval is hybrid and auditable.** `MemoryRetrievalScorer` combines exact
structured agreement, lexical relevance, recency decay and use count, keeping
the breakdown rather than collapsing to one number. A memory sharing nothing
with the query is dropped rather than ranked last, so an unrelated question
recalls nothing instead of the newest thing in the store.
`SemanticSimilarityProviding` is where an embedding model plugs in later.

**A remembered answer reorders, it does not decide.** When two calendars share
a name, SARA puts the one you chose last time first — and still asks.
Auto-selecting would act on an inference you never confirmed for *this*
request, which is the thing the ambiguity rule exists to prevent.

**A turn has phases, and the UI shows them.** Interpreting and validating a
request is "thinking"; writing to EventKit is a separate step the user should
see, especially right after they agreed to a deletion. `ConversationManager`
announces it through a `TurnProgressObserving` passed *per turn* rather than
stored, so nothing has to be wired in the right order at start-up and a turn's
progress cannot outlive it. The announcement fires only for work that actually
runs — a turn that merely asks a question never claims to be executing.

**Permissions are requested at the point of use.** `PlanValidator` asks for
calendar access when a plan contains a calendar action, and reminders access
when it contains a reminder action — not at launch, and not both at once.

**Actors where the framework demands it.** `EKEventStore` is not thread-safe, so
each service owns one and is an actor. They deliberately do not share a store;
authorization is per app, so nothing is lost.

## Extension points

- **A new tool** (Notes, Messages): add an `ActionType`, a payload, an
  `ExecutableOperation`, and a case in `ToolRouter`. Nothing upstream changes.
- **A new AI provider**: conform to `AIProvider` and map its output to
  `ExtractedSlots`. `SlotPlanBuilder` handles the rest, so every provider
  produces identical semantics.
- **A wake word**: `SpeechRecognizing` is a protocol; an engine can sit in front
  of `SpeechManager` without the UI or pipeline knowing.
- **Semantic recall**: implement `SemanticSimilarityProviding`; the scorer's
  weights already leave room for it.
- **CloudKit sync**: the SwiftData schema is deliberately flat and
  identifier-keyed, so a synced configuration is a configuration change rather
  than a migration.
- **Cloud keys**: `AIProvider` is the seam. Keys belong in a backend, reached
  through a provider implementation — never in the app bundle.
