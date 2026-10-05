# Frontend design parity — 2026-10-04

This frontend-only phase supersedes the proposed immediate XPC phase. It implements the supplied approved designs; no new design, daemon installation, backend, protocol or authentication work is in scope. The complete source archive is materialized at `/private/tmp/kaban-frontend-reference/design`, reference PNGs at `/private/tmp/kaban-frontend-reference/png`, brand and mascot kits alongside. Latest matching v0.2.1 revisions take precedence in runtime; historical frames keep distinct fixtures for inspection.

## Full reference inventory

30 downloaded PNGs contain 28 unique frames. Two duplicate git pairs have identical SHA256 and use canonical filenames. The 28 route IDs below are generated from the app reference manifest. A route or exported filename is coverage evidence only; it is not proof of visual parity.

| Frame | Approved source | Theme | Viewport pt | Route | Current evidence |
|---|---|---|---|---|---|
| base/01-board | board.html | light | 1440×900 | board-base | Source DOM exported; composition reviewed; font/compositor limits below |
| base/01-board-dark | board-dark.html | dark | 1440×900 | board-base | Source DOM exported; composition reviewed; font/compositor limits below |
| base/02-cards | cards.html | light | 1440×2070 | cards-base | Source DOM exported; composition reviewed; font/compositor limits below |
| base/03-task-details | task-details.html | light | 1440×900 | incident | Source DOM exported; composition reviewed; font/compositor limits below |
| base/03b-human-review | human-review.html | light | 1440×900 | review | Source DOM exported; composition reviewed; font/compositor limits below |
| base/04-column-settings-git | column-settings-git.html | light | 1440×900 | stage-git-base | Source DOM exported; composition reviewed; font/compositor limits below |
| base/05-column-settings-general | column-settings-general.html | light | 1440×900 | general | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/01-board-limits-flags | v0.2/board.html | light | 1440×900 | board-v02 | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/01-board-limits-flags-dark | v0.2/board-dark.html | dark | 1440×900 | board-v02 | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/02-cards-states | v0.2/cards.html | light | 1440×1060 | cards-v02 | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/03-details-model-substituted | v0.2/details-substituted.html | light | 1440×900 | substituted | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/03-details-model-substituted-dark | v0.2/details-substituted-dark.html | dark | 1440×900 | substituted | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/03b-details-run-limit | v0.2/details-run-limit.html | light | 1440×900 | run-limit | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/04-pipeline-invalid | v0.2/pipeline-invalid.html | light | 1440×900 | pipeline-invalid | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/05-project-mcp | v0.2/project-mcp.html | light | 1440×900 | project-mcp | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2/06-mac-quota-menubar | v0.2/mac-quota.html | light | 1440×900 | mac-quota | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/01-cards-suspicious | v0.2.1/cards.html | light | 1440×900 | cards-suspicious | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/01c-cards-bounce-limits | v0.2.1/cards-bounce-limits.html | light | 1440×720 | cards-bounce | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/02-details-suspicious | v0.2.1/details-suspicious.html | light | 1440×900 | suspicious | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/02-details-suspicious-dark | v0.2.1/details-suspicious-dark.html | dark | 1440×900 | suspicious | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/02b-details-suspicious-stale | v0.2.1/details-suspicious-stale.html | light | 1440×900 | stale | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/03-project-git-presets | v0.2.1/project-git.html | light | 1440×900 | project-git | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/04-stage-git-overrides | v0.2.1/stage-git.html | light | 1440×900 | stage-git | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/05-return-sheet-gate | v0.2.1/return-sheet-gate.html | light | 1440×900 | return-gate | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/05-return-sheet-gate-dark | v0.2.1/return-sheet-gate-dark.html | dark | 1440×900 | return-gate | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/05b-return-sheet-merge | v0.2.1/return-sheet-merge.html | light | 1440×900 | return-merge | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/06-add-project-identity | v0.2.1/add-project-identity.html | light | 1440×900 | add-project | Source DOM exported; composition reviewed; font/compositor limits below |
| v0.2.1/06-add-project-identity-dark | v0.2.1/add-project-identity-dark.html | dark | 1440×900 | add-project | Source DOM exported; composition reviewed; font/compositor limits below |

## Implementation and evidence

Visual review showed that translating the CSS layout to native controls produced substantial geometry differences. The approved implementation therefore uses the original local HTML/CSS/SVG components in WKWebView inside the SwiftUI shell. The native prototype remains selectable; it is not claimed as an exact transfer. Original comparison-frame previews are read-only and keep their own fixtures. Main runtime uses latest board21 and allowlisted handlers backed by memory-only ReferenceDemo. No mockup raster is displayed as UI.

All 46 approved HTML/CSS/JS files are bundled byte-for-byte unchanged. The checked-in `frontend-design-source-manifest-2026-10-04.json` records their SHA256 and the 28 unique reference PNG SHA256/viewport dimensions. Runtime entrypoints, demo-bridge.js and macos-compatibility.js are separate implementation files. External network resources and navigation outside the bundled Design directory are blocked. No shell/repository/daemon commands are exposed by the bridge.

The explicit macOS compatibility adjustment groups General's eleven source fboxes into three columns [0–2], [3–6], [7–10], matching the approved PNG. WebKit's CSS column balancing placed Переходы in the wrong column. Original bytes remain unchanged. Long galleries can scroll in a shorter application viewport; their full-height export retains source dimensions.

Final captures are `/tmp/kaban-source-final`, exported by the compiled app with WKWebView.takeSnapshot: 28 original source frames plus two projected latest runtime boards. `frames.json` records source path, theme, viewport, actual pixels, source/render SHA256 and honest result/findings per frame. Root reviewed all 28 compositions through seven paired comparison sheets at `/tmp/kaban-parity-qa/comparison-01.png` through `comparison-07.png`; General was the sole major layout mismatch and received the compatibility correction.

**Visual limits:** System fonts/emoji differ from the supplied renderer, causing some text wraps and card heights to differ. WebKit takeSnapshot omits some backdrop-filter compositing: underlying board text can be sharper than the reference under detail/modal glass. Source layout and every supplied section are present, but this evidence does not establish pixel-perfect equivalence. No hidden failed frame is counted as verified.

## Functional verification and scope

The unsigned Xcode Debug build succeeds at `/tmp/kaban-parity-derived/Build/Products/Debug/Kaban.app`; actual generated Info.plist contains CFBundleIconFile `Resources/Kaban.icns`, and that original icon exists under Contents/Resources/Resources. The running app also assigns this icon to its own NSApplication instance, without system settings changes. App resources require no font/system installation.

Frontend smoke passes 35 checks (`/tmp/kaban-dom-smoke-final.json`). Thirteen direct memory-state checks cover exact Markdown/create/edit/move/cancel, project identity validation, scoped pending/stale file acceptance and settings snapshots. Actual DOM checks exercise project selection, native editor/move/cancel projection, file acceptance, original project modal input/submit, new project lane/task persistence across projection and navigation, selected-task return, literal HTML safety, sequential typing focus, empty return acceptance, preset apply/cancel/reload and automatic SwiftUI NSHostingView observation without manually projecting the runtime. Unknown bridge actions, remote URLs and paths outside the bundle are rejected. Smoke/export failures exit nonzero and stale outputs are removed.

The parent verified KABAN_SCENARIOS=Scenarios/M1: 294 package tests, zero failures/no skips; log `/private/tmp/kaban-parity-package-tests.log`. App-only code is covered separately by the smoke/build/export checks. No package changes were made during this frontend phase, so the package suite was not repeated.

Demo data and mutations exist only during the current launch. Native create/edit/move/cancel forms remain usable where originals are absent; original return and identity modal geometry is reused for drawn forms. Acceptance sets and pending operations are scoped per task. Resume/move queues a stage and never restores running. Settings apply/cancel restores the memory snapshot. Diff/file controls open a local illustrative viewer. Real file navigation, durable state, authoritative commands/events, quota and settings integration remain the future adapter to existing BoardStore/KabanClient and DTOs; no new protocol contract is requested.

Original archives contain no create-task or empty-board frame; v0.2.1 explicitly defers suspicious-file settings. These are undrawn rather than omitted drawn references. The macOS Демо menu routes all 28 original frames outside the reference viewport, and the brand screen uses the supplied outlined wordmark/icon. This is implementation of approved designs, not new designer work. Root owns final PR/CI/runtime launch; no merge is performed by frontend.
