# Kaban.app foundation

Open `Kaban.xcodeproj`, select the shared **Kaban** scheme, and run on macOS 26 or later with Xcode 27. The app imports only `KabanProtocol` and `KabanBoardCore` from the local Swift package. The Debug configuration builds the active architecture. Signing is optional for local compilation; an unsigned build requires no signing identity or Keychain changes:

```sh
xcodebuild -project Kaban.xcodeproj -scheme Kaban \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/kaban-app-build CODE_SIGNING_ALLOWED=NO build
swift test --filter Team2TakeoverFrontendFoundationTests
```

This stage uses `MockKabanClient` with two project fixtures. The toolbar identifies demo data. The sidebar context menu shows or hides projects, and the board persists the visible project set in app UserDefaults. Selecting a task loads typed `TaskDetail` through the client. Running tasks can be paused and resumed through commands: the board changes only after the mock publishes a correlated `taskUpdated` event. Unsupported commands return an explicit error. Mock pause/resume models demonstration states, not daemon process suspension.

Card typography, spacing, radii, semantic status colours and suspicious-file rows follow the approved v0.2.1 token/reference archive. The foundation uses native SwiftUI materials and controls. Whole-window visual comparison, exact dark appearance token mapping, mascots, drag-and-drop, keyboard lane navigation and complete task actions remain unverified or pending. This is a structural implementation of the existing design, not a redesign.

Real XPC connection/reconnect, quota/settings editors, pipeline/project editors, incident screens, Human Review actions, daemon registration and signing are later stages. No daemon is installed or started by this app. Settings are not inferred from missing snapshot fields. WIP appears only when authoritative `StageLoad` is available; sidebar/global counts use all projects regardless of which lanes are visible.
