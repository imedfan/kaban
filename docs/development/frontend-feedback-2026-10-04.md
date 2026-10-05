# Frontend feedback — 2026-10-04

Frontend-only work. These requests are recorded for later coordination; no backend/architecture agent is asked to implement them during this phase.

| ID | Follow-up | User-visible impact | Existing contract and scope |
|---|---|---|---|
| F001 | Adapt ReferenceDemo/UI fixtures to existing BoardStore/KabanClient typed commands, DTOs and journal events | Production actions must wait for authoritative correlated events, handle command errors and refresh stale sets | Protocol DTOs already contain project/stage settings, identity and quota. This requests an adapter/integration, not a new protocol contract. Demo string fixtures are temporary frontend state. |
| F002 | Retain undrawn-screen audit | Exact geometry cannot be proved for create-task, empty-board and suspicious-file settings | Complete archives were inspected; root confirmed no original create/empty screen. v0.2.1 defers suspicious-file settings. Usable forms continue without blocking. |
| F003 | Connect file/diff navigation using provided task clonePath and accepted/suspicious blob pairs | Users need actual scoped file navigation and safe stale acceptance feedback | Existing TaskDetail supplies fields. Demo opens a local illustrative diff; it does not execute Cursor/Finder/system commands. |
| F004 | Wire settings apply/cancel and runtime counts to authoritative project identities, settings and quota snapshots | A memory-only action must not imply durable save, and demo totals must not become production values | Existing typed APIs remain unchanged. Frontend snapshot restore is tested separately; no daemon install/start or real quota/auth fetch in this phase. |

The approved frontend decision is now bundled original HTML/CSS/SVG in WKWebView inside the SwiftUI shell, with a typed allowlisted Swift demo bridge. The native prototype remains available for inspection. No raster mockup is used as UI. Original source hashes remain unchanged. This replaces the native geometry transfer that visual review found inaccurate; it does not introduce new design or backend work.

F005 — WK `takeSnapshot` can omit backdrop-filter compositing even when the DOM/CSS is unchanged. Export evidence must distinguish renderer limitations from application layout. Original frame previews are read-only; current runtime actions restore memory state on each navigation. Production integration should retain the existing DTO nil/unknown semantics, pending command correlation, stale-set handling and authoritative counts rather than importing demo string fixtures.
