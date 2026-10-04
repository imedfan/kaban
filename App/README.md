# Kaban.app foundation

Open `Kaban.xcodeproj`, select the shared **Kaban** scheme, and run on macOS 26 or later with Xcode 27. The app imports only `KabanProtocol` and `KabanBoardCore` from the local Swift package. The Debug configuration builds the active architecture. Signing is optional for local compilation; an unsigned build requires no signing identity or Keychain changes:

```sh
xcodebuild -project Kaban.xcodeproj -scheme Kaban \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/kaban-board-derived CODE_SIGNING_ALLOWED=NO build
swift test --filter Team2TakeoverFrontendFoundationTests
```

This stage uses `MockKabanClient` with two project fixtures. The toolbar identifies demo data. The sidebar context menu shows or hides projects, and the board persists the visible project set in app UserDefaults. Selecting a task loads typed `TaskDetail` through the client. New tasks are created in the selected project’s Backlog with a title, Markdown description, and an explicit acceptance criteria section composed into the existing `createTask(title, body)` contract. Known Markdown bodies can be edited exactly; legacy `TaskDetail.body == nil` disables body editing and sends title-only changes without replacing unknown content. Move uses the existing drop rules with interruption confirmation, and cancellation explicitly offers branch preservation. Empty projects/boards, pending commands, failures, and stale task selection have native affordances.

The mock validates each command against its current card, rejects unsupported commands explicitly, and replays the same `commandId` without duplicate effects; reusing it for a different command conflicts. Cards and loads change through correlated journal events. Creation waits for `taskCreated`, including event-before-ack races. Running tasks can be paused; resume queues the same stage instead of restoring a running state. Mock actions demonstrate states and do not control processes or modify repositories. Snapshot resync invalidates stale detail requests and reconciles visible projects and selection.

Card typography, spacing, radii, semantic status colours and suspicious-file rows follow the approved v0.2.1 token/reference archive. The foundation uses native SwiftUI materials and controls. Whole-window visual comparison, exact dark appearance token mapping, mascots, drag-and-drop and keyboard lane navigation remain unverified or pending. Action sheets use native controls; original create-sheet visual fidelity remains pending because that reference is unavailable. This is a structural implementation of the existing design, not a redesign.

Real XPC connection/reconnect, quota/settings editors, pipeline/project editors, incident screens, Human Review actions, daemon registration and signing are later stages. No daemon is installed or started by this app. Settings are not inferred from missing snapshot fields. WIP appears only when authoritative `StageLoad` is available; sidebar/global counts use all projects regardless of which lanes are visible.
