# Kaban.app — native SwiftUI client

Open `Kaban.xcodeproj`, select **Kaban**, and run on macOS 26+ with a full Xcode.
The main WindowGroup uses `BoardView`, `BoardStore`, `KabanClient` and
`BoardProjection`. `AppFixture` supplies Protocol DTOs through `MockKabanClient`;
the views do not implement a second task state machine.

The board, project sidebar, task cards, detail overlay and action sheets follow
the composition and light/dark tokens pinned in [design](../design/README.md).
The macOS window keeps system traffic lights; product controls retain visible
text at a stable size. The board scrolls horizontally when its columns cannot
fit. Details overlay the board without squeezing columns.

Create, edit, move, cancel and task pause/resume use typed commands. Selection,
status and pending operations resolve through correlated journal events.
Cmd-N creates a task; Cmd-F focuses search; Escape closes details. Project
visibility persists in UserDefaults. Task data remains in memory for this launch.

Project settings display the values supplied by the current snapshot. Settings
editing, global/project pause, quota, Human Review decisions and file acceptance
still need client/backend support. Missing quota and policy values display as
unknown. No daemon, Cursor process or system registration is started.

```sh
xcodebuild -project Kaban.xcodeproj -scheme Kaban \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/kaban-polish-app \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
/tmp/kaban-polish-app/Build/Products/Debug/Kaban.app/Contents/MacOS/Kaban
```

Opt-in QA uses the **actual application WindowGroup** with isolated in-memory
board preferences. These arguments are inactive during an ordinary launch:

```sh
/tmp/kaban-polish-app/Build/Products/Debug/Kaban.app/Contents/MacOS/Kaban \
  --export-live-window /tmp/kaban-board.png --qa-theme light
/tmp/kaban-polish-app/Build/Products/Debug/Kaban.app/Contents/MacOS/Kaban \
  --export-live-window /tmp/kaban-details.png --qa-state details --qa-theme dark
/tmp/kaban-polish-app/Build/Products/Debug/Kaban.app/Contents/MacOS/Kaban \
  --ui-smoke /tmp/kaban-ui-smoke.json
```

Other QA states: `minimum`, `long`, `empty`, `hidden`, `search`, `no-results`,
`project`, `quota`, `review`, `create`, `edit`, `move`, `cancel`, `error`.
The smoke checks the mounted window, typed action/event flow and real menu
shortcuts. AppKit view caching captures layout but does not prove compositor
fidelity, VoiceOver, manual pointer interactions or every accessibility setting.

The older `Reference*` views remain comparison tools. Their gallery captures
and separate `ReferenceDemo` fixtures are not the main application runtime and
are not evidence of main-window acceptance. Historical reports in
`docs/development/frontend-design-parity-2026-10-04.md` describe earlier revisions.
