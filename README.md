# SARA

A voice-first iOS assistant that manages Calendar events and Reminders through
natural language.

    AI proposes. SARA validates. EventKit executes. SARA verifies.

## Requirements

- Xcode 26 or later, iOS 26 SDK
- An iOS 26 simulator or device

## Build and run

```bash
open SARA.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project SARA.xcodeproj -scheme SARA \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Tests

Domain and pipeline tests run on the host in under a second, with no simulator:

```bash
cd Packages/SARAKit && swift test
```

Integration tests run in the simulator against the real EventKit database. They
are skipped unless both permissions are granted:

```bash
xcrun simctl privacy booted grant calendar com.sara.assistant
xcrun simctl privacy booted grant reminders com.sara.assistant
xcodebuild -project SARA.xcodeproj -scheme SARA \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Layout

```
SARA/
├── App/SARA/              iOS app target — lifecycle only
├── Packages/SARAKit/
│   ├── Sources/SARACore/  Domain: plans, validation, temporal, conversation
│   ├── Sources/SARAKit/   Infrastructure and SwiftUI presentation
│   ├── Sources/SARATesting/  In-memory service doubles
│   └── Tests/
└── IntegrationTests/      Real EventKit, runs in the simulator
```

SARA stores preferences, action history, recent turns and remembered choices
locally with SwiftData. Nothing is synced anywhere, and calendar and reminder
records are never duplicated into it — EventKit stays the source of truth.

`SARACore` has no framework dependencies, which is why its tests are fast.
Everything that touches EventKit, Speech or Foundation Models lives in
`SARAKit`, behind protocols declared in `SARACore`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the pipeline and the decisions
behind it.
