# Kaban.app: native SwiftUI client

Open `Kaban.xcodeproj`, select **Kaban**, and run on macOS 26+ with a full Xcode.
The main WindowGroup uses `DaemonRuntime`, `BoardView`, `BoardStore`, and the
Protocol-based `KabanClient` and `BoardProjection`. Normal launches connect to
the installed daemon. `--developer` uses the bundled daemon over private stdio.
Tasks and history belong to the daemon database.

The board, project sidebar, task cards, detail overlay, and action sheets follow
the composition and light/dark tokens pinned in [design](../design/README.md).
`KabanTheme`, `KabanMascot`, `KabanChip`, `KabanBackdrop`, and `KabanWordmark`
are shared product components. The unused `ReferenceDemo` screens and
`NativeShell` have been removed. Original design sources remain in `design/`.

Commands use typed DTOs. Status and pending operations resolve through
correlated journal events. Missing quota and policy values display as unknown.
See [current state](../docs/current-state.md) for supported flows and open
backend and installation requirements.

## Build and check application contents

Debug enables the compile condition `KABAN_QA`. Release does not enable it.
`AppFixture`, BoardQA, native capture, and the QA clients compile only with that
condition. An ordinary Release ignores QA arguments and contains none of those
types. The explicit developer database option works in both configurations.

```sh
xcodebuild -project Kaban.xcodeproj -scheme Kaban -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/kaban-release \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
python3 tools/check-app-build-contents.py \
  --app /tmp/kaban-release/Build/Products/Release/Kaban.app
```

The checker reads actual Mach-O symbols, including `Kaban.debug.dylib` when
present. It rejects demo types in every configuration and QA types in a
production build. For a QA build, pass `--qa`; the checker also requires
BoardQA, AppFixture, native capture, and the shared product components.
CI checks Debug QA and production Release and runs the existing native smoke.
Unsigned verification does not confirm installed helper or login permissions.

## Run native QA

Build Debug before using the opt-in QA arguments. The fixture path supplies
Protocol DTOs through `MockKabanClient` with isolated board preferences.
It does not connect to the installed daemon. Live drivers use a new private
repository and daemon database and describe that transport in their reports.

```sh
xcodebuild -project Kaban.xcodeproj -scheme Kaban -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/kaban-qa \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
python3 tools/check-app-build-contents.py \
  --app /tmp/kaban-qa/Build/Products/Debug/Kaban.app --qa
open -n -W /tmp/kaban-qa/Build/Products/Debug/Kaban.app --args \
  --export-live-window /tmp/kaban-board.png --qa-theme light
open -n -W /tmp/kaban-qa/Build/Products/Debug/Kaban.app --args \
  --ui-smoke /tmp/kaban-ui-smoke.json
```

Other QA states include `minimum`, `long`, `empty`, `hidden`, `search`,
`no-results`, `project`, `review`, `create`, `edit`, `move`, `cancel`, and `error`.
BoardQA checks the actual application WindowGroup, typed actions and events,
and native menu shortcuts. AppKit view caching captures layout and does not
prove compositor fidelity, VoiceOver, or every accessibility setting.
[FE-34 verification](../docs/development/frontend-fe-34-2026-10-09.md) records
build conditions, native results, and open checks.
