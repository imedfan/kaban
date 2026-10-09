#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func projectSettingsLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = AppArguments.value("--settings-live-repository"), path.hasPrefix("/tmp/kaban-fe15-"),
              AppArguments.value("--developer-database")?.hasPrefix("/tmp/kaban-fe15-") == true,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private settings fixture or WindowGroup missing") }
        window.setContentSize(AppArguments.value("--qa-size") == "minimum" ? .init(width: 1040, height: 640) : .init(width: 1440, height: 900))
        if !store.macPaused { _ = await store.session.send(.pauseAll) }
        try await waitUntil("Mac pause before configuration QA") { store.macPaused && store.canSend }
        if store.projection?.projects.values.contains(where: { $0.path == path }) != true {
            _ = await store.session.send(.addProject(path: path, createTemplate: false, identity: .init(name: "Settings QA", email: "settings@example.test")))
            try await waitUntil("real settings project and reconciliation") { store.projection?.projects.values.contains { $0.path == path } == true && store.canSend }
        }
        guard let project = store.projection?.projects.values.first(where: { $0.path == path }) else { throw failure("Project missing") }
        store.selectedProjectID = project.id; store.screen = .project(project.id); store.showPipelineIssues = false
        let settings = store.settings(for: project.id)
        let mode = AppArguments.value("--qa-settings-mode") ?? "metadata"
        var checks = ["real WindowGroup and private production daemon; Mac paused"]
        if mode == "flow" || mode == "identity-refusal" {
            let previousIdentity = settings.project?.identity
            settings.begin(.identity); settings.editIdentity(.name, value: "Typed author 👋"); settings.editIdentity(.email, value: "")
            _ = await settings.submit()
            guard settings.error != nil, settings.identity.name.value == "Typed author 👋", settings.identity.email.highlighted,
                  settings.project?.identity == previousIdentity else { throw failure("Identity refusal lost input or changed project") }
            checks.append("real identity_required keeps input and authoritative author")
            if mode == "flow" {
                settings.editIdentity(.email, value: "typed@example.test")
                guard await settings.submit() else { throw failure("Identity command send refused") }
                try await waitUntil("correlated identity projectUpdated and reconciliation") { settings.record?.phase == .applied && store.canSend }
                settings.observeOutcome()
                settings.begin(.resources); settings.editWeight("0"); settings.editMaxRuns("2")
                _ = await settings.submit()
                guard settings.error != nil, settings.weight == "0", settings.project?.weight != 0 else { throw failure("Resource refusal changed project or lost input") }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                try await waitUntil("native weight field") {
                    window.contentView.map { descendants($0).compactMap { $0 as? NSTextField }.contains { $0.isEditable && $0.stringValue == "0" } } == true
                }
                guard let root = window.contentView,
                      let field = descendants(root).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.stringValue == "0" }) else { throw failure("Weight field missing") }
                window.makeKeyAndOrderFront(nil); NSApp.activate()
                try await waitUntil("native weight focus") {
                    if field.currentEditor() == nil { window.makeFirstResponder(field) }
                    return field.currentEditor() != nil
                }
                guard let native = field.currentEditor() as? NSTextView else { throw failure("Weight field editor missing") }
                native.setSelectedRange(.init(location: 0, length: (native.string as NSString).length))
                native.insertText("4", replacementRange: native.selectedRange()); window.makeFirstResponder(nil)
                try await waitUntil("native weight binding") { settings.weight == "4" }
                window.makeKeyAndOrderFront(nil); NSApp.activate(); NSApp.mainMenu?.update()
                guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                      NSApp.mainMenu?.performKeyEquivalent(with: key) == true else { throw failure("Metadata Cmd-Return route missing") }
                try await waitUntil("correlated weight projectUpdated and reconciliation") { settings.record?.phase == .applied && store.canSend }; settings.observeOutcome()
                await store.setMascot(project.id, index: 5, texture: .waves)
                guard let mascotCommand = store.commandJournal?.records.last,
                      case .setMascot(let id, _) = mascotCommand.envelope.command, id == project.id else { throw failure("Mascot command send refused") }
                try await waitUntil("correlated authoritative mascot and reconciliation") {
                    store.commandJournal?.records.first { $0.envelope.commandId == mascotCommand.envelope.commandId }?.phase == .applied && store.canSend &&
                    store.mascot(project.id).mascotIndex == 5 && store.mascot(project.id).texture == .waves
                }
                checks.append("real author/weight/maxRuns/mascot writes confirmed by projectUpdated")
                checks.append("native weight field and Cmd-Return save route")
            }
        }
        if mode == "reopen" {
            guard settings.project?.identity == .init(name: "Typed author 👋", email: "typed@example.test"), settings.project?.weight == 4,
                  settings.project?.maxRuns == 2, store.mascot(project.id).mascotIndex == 5 else { throw failure("Metadata not durable after restart") }
            checks.append("restart restores author, resources and mascot from daemon DB")
        }
        if mode == "resources" { settings.begin(.resources) }
        if mode == "long-identity" {
            settings.begin(.identity)
            settings.editIdentity(.name, value: String(repeating: "Длинное имя автора 👋 ", count: 25))
            settings.editIdentity(.email, value: String(repeating: "long.address.", count: 20) + "example.test")
            checks.append("long identity draft stays exact in native fields")
        }
        if mode == "flow" || mode == "pipeline" || mode == "invalid-size" || mode == "disconnected" {
            store.openPipelineIssues(project.id)
            let editor = store.pipelineEditor(for: project.id); await editor.loadIfNeeded()
            try await waitUntil("settings shared pipeline editor") { store.activePipelineEditor === editor }
            func validate() async throws {
                let hash = editor.draft?.contentHash
                await editor.validate()
                try await waitUntil("current settings draft validation") {
                    guard case .checked(let result) = editor.validation else { return false }
                    return result.contentHash == hash
                }
            }
            if mode == "flow" {
                editor.patch("workspace.warm_paths", value: "[\"build cache 👋\", \"node_modules\"]")
                editor.patch("workspace.on_create", value: "echo ready", quoted: true)
                editor.patch("suspicious_files.patterns", value: "[\"*.secret\", \"*.pem\"]")
                editor.patch("suspicious_files.max_file_mb", value: "12.5")
                editor.patch("suspicious_files.allow", value: "[\".env.example\", \"fixture.pem\"]")
                editor.setGitRule("cherry-pick", allowPath: "git.allow", denyPath: "git.deny", decision: .deny)
                guard let index = editor.document.stages.first(where: { $0.id == "dev" })?.index else { throw failure("Dev missing") }
                let prefix = "stages[\(index)].git"
                editor.setGitRule("rebase", allowPath: prefix + ".extend", denyPath: prefix + ".deny", decision: .allow)
                editor.patch(prefix + ".when", value: "return_reason == merge_conflict", quoted: true)
                try await validate()
                guard editor.canApply, let resolved = editor.lastResolved,
                      resolved.projectGitPolicy?.denied.contains(.init("cherry-pick", source: .project)) == true,
                      resolved.stages.first(where: { $0.id == "dev" })?.gitPolicy?.conditional.first?.returnReason == "merge_conflict",
                      resolved.projectGitPolicy?.hardInvariants == HardInvariant.all else { throw failure("Server resolved policy differs from configured draft") }
                let accepted = editor.content
                editor.patch("suspicious_files.max_file_mb", value: "0"); try await validate()
                guard !editor.canApply, editor.content.contains("max_file_mb: 0") else { throw failure("Invalid file setting can apply or lost draft") }
                editor.edit(accepted, debounce: false); try await validate(); await editor.apply()
                try await waitUntil("correlated settings pipelineApplied") { editor.isApplied }; await editor.confirmApplied()
                guard editor.source?.committedContent == accepted, accepted.contains("future_extension: preserved"), accepted.contains("# preserve this comment"),
                      store.projection?.pipelines[project.id]?.projectGitPolicy == resolved.projectGitPolicy,
                      store.projection?.pipelines[project.id]?.stages.first(where: { $0.id == "dev" })?.gitPolicy == resolved.stages.first(where: { $0.id == "dev" })?.gitPolicy else { throw failure("Saved source or policy mismatch") }
                checks.append("shared exact draft writes workspace/files/project and stage policy; validation blocks zero size")
                checks.append("backend preview equals applied policy; unknown fields survive; hard invariants remain locked")
            }
            if mode == "invalid-size" {
                editor.patch("suspicious_files.max_file_mb", value: "0"); try await validate()
                guard !editor.canApply, editor.document.value("suspicious_files.max_file_mb") == "0" else { throw failure("Invalid size lost draft or permits apply") }
                checks.append("zero size blocked by server validation; field draft retained")
            }
            if mode == "disconnected" {
                editor.edit(editor.content + "# Offline settings draft 👋\n", debounce: false)
                let draft = editor.content
                store.session.stop(); await editor.validate()
                guard editor.content == draft, !editor.canApply, !store.canSend else { throw failure("Disconnect lost settings draft or permits apply") }
                checks.append("disconnected native editor keeps exact unsent settings draft")
            }
        }
        if AppArguments.value("--export-live-window") != nil { try await captureWindow() }
        return checks
    }
}
#endif
