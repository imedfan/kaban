import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func projectMCPLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = argument("--mcp-live-repository"), path.hasPrefix("/tmp/kaban-fe16-"),
              argument("--developer-database")?.hasPrefix("/tmp/kaban-fe16-") == true,
              let personalPath = argument("--qa-personal-mcp-config"), personalPath.hasPrefix("/tmp/kaban-fe16-"),
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private MCP fixture or WindowGroup missing") }
        window.setContentSize(argument("--qa-size") == "minimum" ? .init(width: 1040, height: 640) : .init(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        if !store.macPaused { _ = await store.session.send(.pauseAll) }
        try await waitUntil("Mac paused before MCP QA") { store.macPaused && store.canSend }
        if store.projection?.projects.values.contains(where: { $0.path == path }) != true {
            _ = await store.session.send(.addProject(path: path, createTemplate: false, identity: .init(name: "MCP QA", email: "mcp@example.test")))
            try await waitUntil("real MCP project") { store.projection?.projects.values.contains { $0.path == path } == true }
        }
        guard let project = store.projection?.projects.values.first(where: { $0.path == path }) else { throw failure("Project missing") }
        store.selectedProjectID = project.id; store.screen = .project(project.id); store.showPipelineIssues = false
        let settings = store.mcpSettings(for: project.id), mode = argument("--qa-mcp-mode") ?? "settings"
        let personal = try Data(contentsOf: URL(fileURLWithPath: personalPath))
        await settings.load()
        store.mcpProjectID = project.id
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil("MCP catalog load") { settings.catalogState != .loading && settings.catalogState != .unknown }
        var checks = ["real WindowGroup, private production daemon and catalog query; Mac paused"]
        if mode == "read-error" {
            guard case .failed = settings.catalogState, settings.catalog == nil, !settings.canEdit else { throw failure("Read failure shown as empty catalog or writable") }
            checks.append("malformed personal config is an explicit read failure, not empty servers")
        } else {
            guard let catalog = settings.catalog, catalog.contains(.init(name: "github", source: .project)), catalog.filter({ $0.name == "shared" }).count == 2,
                  settings.allowed?.contains("kaban") == true else { throw failure("Catalog sources or mandatory board missing: \(settings.catalogState); allowed=\(String(describing: settings.allowed))") }
            let count = store.commandJournal?.records.count
            _ = await settings.setAllowed("kaban", enabled: false)
            guard store.commandJournal?.records.count == count else { throw failure("Kaban emitted a disable command") }
            checks.append("project/personal source collision stays visible; kaban cannot emit disable")
            if mode == "flow" {
                try await waitUntil("native MCP switch") { findAccessibility(window, identifier: "mcp-allow-project-github") != nil }
                guard let toggle = findAccessibility(window, identifier: "mcp-allow-project-github"), pressAccessibility(toggle) else { throw failure("Native MCP switch press failed") }
                try await waitUntil("correlated native MCP toggle") { settings.receipt?.phase == .applied && settings.allowed?.contains("github") == true }
                if let other = argument("--mcp-other-repository"), other.hasPrefix("/tmp/kaban-fe16-") {
                    _ = await store.session.send(.addProject(path: other, createTemplate: false, identity: .init(name: "Other QA", email: "other@example.test")))
                    try await waitUntil("second MCP project") { store.projection?.projects.values.contains { $0.path == other } == true }
                    guard store.projection?.projects.values.first(where: { $0.path == other })?.mcpAllowlist == ["kaban"] else { throw failure("MCP permission crossed projects") }
                }
                checks.append("actual native switch sends command; correlated permission remains isolated to one project")
            }
            if mode == "reopen" {
                guard settings.allowed?.contains("github") == true else { throw failure("Permission not restored after restart") }
                checks.append("restart restores daemon allowlist")
            }
            if mode == "unexpected" || mode == "unexpected-board" {
                guard settings.project?.mcpIssue == .init(kind: .unexpected, name: "rogue") else { throw failure("Seeded MCP diagnostic missing") }
                await store.recheckProject(project.id)
                try await waitUntil("MCP diagnostic after project recheck") { store.recheckRecord(project.id)?.phase == .applied && store.canSend }
                await settings.load()
                guard settings.project?.mcpIssue?.name == "rogue", settings.allowed == ["kaban", "github"] else { throw failure("Recheck cleared MCP block or approved every server") }
                checks.append("seeded preflight fact stays visible after real project recheck; no live CLI producer claimed")
                if mode == "unexpected-board" {
                    store.mcpProjectID = nil; store.screen = .board
                    try await Task.sleep(for: .milliseconds(300))
                    store.focusProject(project.id)
                }
            }
            if mode == "stage" || mode == "apply" || mode == "disconnected" {
                store.mcpProjectID = nil; store.openPipelineIssues(project.id)
                let editor = store.pipelineEditor(for: project.id); editor.selectedStageID = "dev"; editor.section = "Исполнитель"
                await editor.loadIfNeeded()
                try await waitUntil("native MCP stage picker") { store.activePipelineEditor === editor && findAccessibility(window, identifier: "stage-mcp-github") != nil }
                let selected = editor.document.stringList("stages[1].agent.mcp")
                guard selected?.contains("disabled") == true else { throw failure("Disabled stage selection silently removed") }
                await editor.validate()
                try await waitUntil("current MCP draft validation") { if case .checked(let value) = editor.validation { return value.contentHash == editor.draft?.contentHash }; return false }
                guard editor.issues.contains(where: { $0.code == "mcp_not_allowlisted" && $0.severity == .warning }), editor.canApply else { throw failure("Disabled MCP warning blocks valid apply") }
                checks.append("disabled selection remains in YAML; daemon warning permits valid apply")
                if mode == "apply" {
                    guard let toggle = findAccessibility(window, identifier: "stage-mcp-github"), pressAccessibility(toggle) else { throw failure("Native stage MCP press failed") }
                    try await waitUntil("native stage MCP binding") { editor.document.stringList("stages[1].agent.mcp")?.contains("github") == true }
                    await editor.validate()
                    try await waitUntil("current MCP selection validation") { if case .checked(let value) = editor.validation { return value.contentHash == editor.draft?.contentHash }; return false }
                    let exact = editor.content
                    guard editor.canApply else { throw failure("Current MCP draft cannot apply") }
                    await editor.apply()
                    try await waitUntil("correlated MCP pipeline commit and reconciliation") { editor.isApplied && store.canSend }
                    await editor.confirmApplied()
                    try await waitUntil("confirmed MCP source read") { editor.source?.committedContent == exact }
                    guard editor.source?.committedContent == exact, exact.contains("# preserve MCP source 👋"), exact.contains("future_mcp: preserved") else {
                        throw failure("MCP apply source mismatch: committed=\(String(describing: editor.source?.committedContent.map(PipelineContentHash.sha256))), exact=\(PipelineContentHash.sha256(exact)), marker=\(exact.contains("# preserve MCP source 👋")), foreign=\(exact.contains("future_mcp: preserved")), error=\(editor.error ?? "none")")
                    }
                    let dev = store.projection?.pipelines[project.id]?.stages.first { $0.id == "dev" }
                    guard dev?.mcp == ["kaban", "disabled", "github"], dev?.effectiveMcp == ["kaban", "github"] else { throw failure("Backend effective set differs after native apply") }
                    checks.append("actual native stage switch applies exact YAML; server projects selected/effective names")
                }
                let draft = editor.content
                store.mcpProjectID = project.id
                try await waitUntil("MCP project screen from stage") { store.activePipelineEditor == nil }
                try await Task.sleep(for: .milliseconds(300))
                guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
                      window.performKeyEquivalent(with: escape) else { throw failure("MCP Escape route missing") }
                try await waitUntil("stage restored after MCP screen") { store.activePipelineEditor === editor }
                guard editor.content == draft, editor.selectedStageID == "dev", editor.section == "Исполнитель" else { throw failure("MCP navigation lost draft or stage") }
                checks.append("native Escape from MCP restores the same draft, stage and section")
                if mode == "disconnected" {
                    editor.edit(editor.content + "# disconnected MCP draft\n", debounce: false); store.session.stop()
                    await editor.validate()
                    guard !editor.canApply, editor.content.hasSuffix("# disconnected MCP draft\n") else { throw failure("Disconnect lost draft or enabled apply") }
                    checks.append("disconnect keeps MCP draft and disables apply")
                }
            }
        }
        guard try Data(contentsOf: URL(fileURLWithPath: personalPath)) == personal else { throw failure("Personal MCP config was modified") }
        checks.append("personal config bytes unchanged; no run started")
        if mode == "stage" || mode == "apply" || mode == "disconnected" {
            try await Task.sleep(for: .milliseconds(300))
        }
        if argument("--export-live-window") != nil { try await captureWindow() }
        return checks
    }
    private static func findAccessibility(_ window: NSWindow, identifier: String) -> NSSwitch? {
        func find(_ view: NSView) -> NSSwitch? {
            if let control = view as? NSSwitch, control.identifier?.rawValue == identifier { return control }
            return view.subviews.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }
    private static func pressAccessibility(_ control: NSSwitch) -> Bool {
        guard control.isEnabled else { return false }
        control.performClick(nil)
        return true
    }
}
