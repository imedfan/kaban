# Kaban.app — approved design demo

Open `Kaban.xcodeproj`, select **Kaban**, and run on macOS 26 with Xcode 27. The default application displays the approved v0.2.1 board through bundled original HTML/CSS/SVG in a local WKWebView, inside the SwiftUI macOS shell. This implements supplied designs; it does not redesign them. The original Kaban icon is bundled under `Resources/Kaban.icns`; the native brand screen uses the supplied outlined wordmark.

```sh
xcodebuild -project Kaban.xcodeproj -scheme Kaban -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/kaban-parity-derived \
  CODE_SIGNING_ALLOWED=NO build
/tmp/kaban-parity-derived/Build/Products/Debug/Kaban.app/Contents/MacOS/Kaban
```

All changes in the default demo exist only in memory for the current launch. Select a project in the sidebar, use **Задача** to create a task, select a card for details/actions, and use its context menu to move it. Create/edit/move/cancel use native forms where no original form was supplied. Task Markdown is stored exactly in demo memory; moves and resumes queue tasks rather than restoring a running state. Original return and project-identity sheets are interactive DOM components. Accepting files tracks pending/accepted sets per task; project registration adds a sidebar entry and a lane; settings apply/cancel preserve a local snapshot.

The **Демо** macOS menu opens each of the 28 original reference frames, changes appearance, opens the brand screen, or selects the preserved native SwiftUI prototype. Reference previews are read-only and preserve their original fixtures; the main board and settings use allowlisted Swift demo handlers. `--native-demo` starts the native prototype.

```sh
APP=/tmp/kaban-parity-derived/Build/Products/Debug/Kaban.app/Contents/MacOS/Kaban
"$APP" --demo-smoke /tmp/kaban-dom-smoke.json
"$APP" --export-design-frames /tmp/kaban-source-frames
"$APP" --export-design-frames /tmp/kaban-one-frame --frame-id v0.2.1/02-details-suspicious
```

The smoke exercises actual DOM clicks, Swift state, DOM projection, original modals, settings reload and SwiftUI observation, plus direct memory-state checks. Failure exits nonzero. Export uses WKWebView snapshots at reference viewport sizes and records source/render SHA256, actual pixel dimensions, result and limitations in `frames.json`. It exports all 28 originals and two projected runtime boards. `--native-frames` selects the preserved AppKit capture path for diagnostics.

Original sources remain byte-for-byte unchanged; runtime entrypoints and `demo-bridge.js` are separate. Web content is restricted to bundled local resources and blocked from remote network navigation. Demo diff/file actions open an illustrative local viewer; no shell, repository, Cursor/Finder, daemon, authentication or XPC action is executed. Production integration remains an adapter to existing BoardStore/KabanClient typed commands, DTOs and journal events.

WK snapshots have a known backdrop-filter compositor limitation and platform font/emoji differences from supplied PNGs. Rendering original DOM is not a claim that every exported pixel matches the supplied raster. See the [parity audit](../docs/development/frontend-design-parity-2026-10-04.md) and [frontend feedback](../docs/development/frontend-feedback-2026-10-04.md).
