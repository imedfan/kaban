#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func pipelineLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = AppArguments.value("--pipeline-live-repository"), path.hasPrefix("/tmp/kaban-fe13-"),
              AppArguments.value("--developer-database")?.hasPrefix("/tmp/kaban-fe13-") == true,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private pipeline fixture or WindowGroup missing") }
        if AppArguments.value("--qa-size") == "minimum" { window.setContentSize(.init(width: 1040, height: 640)) }
        if store.projection?.projects.values.contains(where: { $0.path == path }) != true {
            _ = await store.session.send(.addProject(path: path, createTemplate: false, identity: .init(name: "Pipeline QA", email: "pipeline@example.test")))
            try await waitUntil("real pipeline project") { store.projection?.projects.values.contains { $0.path == path } == true }
        }
        guard let project = store.projection?.projects.values.first(where: { $0.path == path }) else { throw failure("Project missing") }
        try await waitUntil("connected before pipeline read") { store.canSend }
        store.openPipelineIssues(project.id)
        let editor = store.pipelineEditor(for: project.id)
        await editor.loadIfNeeded()
        try await waitUntil("native pipeline editor") { store.activePipelineEditor === editor }
        guard let source = editor.source else { throw failure(editor.error ?? "Source missing") }
        let exact = source.workingContent ?? ""
        if FileManager.default.fileExists(atPath: source.path) {
            guard try Data(contentsOf: URL(fileURLWithPath: source.path)) == Data(exact.utf8) else { throw failure("Working file differs from source read") }
        } else if source.workingContent != nil { throw failure("Absent file has fabricated content") }
        guard editor.content == exact else { throw failure("Source YAML differs from working bytes") }
        func validateCurrentDraft() async throws {
            let hash = editor.draft?.contentHash
            await editor.validate()
            try await waitUntil("current pipeline validation") {
                guard case .checked(let result) = editor.validation else { return false }
                return result.contentHash == hash
            }
        }
        let mode = AppArguments.value("--qa-pipeline-mode") ?? "apply"
        if mode == "reopen" {
            guard source.committedContent?.contains("# Native exact draft") == true,
                  source.baseVersionHash == store.projection?.pipelines[project.id]?.versionHash else { throw failure("Applied version not durable after restart") }
        }
        if mode == "capture" || mode == "reopen" {
            if AppArguments.value("--export-live-window") != nil { try await captureWindow() }
            return ["real WindowGroup and daemon source", mode == "reopen" ? "restart restores exact committed text and authoritative version" : "native forms and server validation"]
        }
        if let otherPath = AppArguments.value("--pipeline-other-repository"), otherPath.hasPrefix("/tmp/kaban-fe13-") {
            _ = await store.session.send(.addProject(path: otherPath, createTemplate: false, identity: .init(name: "Pipeline QA", email: "pipeline@example.test")))
            try await waitUntil("second real project") { store.projection?.projects.values.contains { $0.path == otherPath } == true }
            try await waitUntil("connected after second project") { store.canSend }
            guard let other = store.projection?.projects.values.first(where: { $0.path == otherPath }) else { throw failure("Second project missing") }
            editor.edit(exact + "# Unsent project draft\n", debounce: false)
            store.openPipelineIssues(other.id)
            let otherEditor = store.pipelineEditor(for: other.id)
            try await waitUntil("switched native editor") { store.activePipelineEditor === otherEditor && otherEditor.source != nil }
            guard editor.content == exact + "# Unsent project draft\n", otherEditor.content == exact else { throw failure("Project switch overwrote or mixed drafts") }
            store.openPipelineIssues(project.id)
            try await waitUntil("original native editor") { store.activePipelineEditor === editor && store.selectedProjectID == project.id }
        }
        editor.edit("version: [\n", debounce: false); try await validateCurrentDraft()
        guard editor.issues.contains(where: { $0.severity == .error }), !editor.canApply else { throw failure("Broken YAML can apply") }
        editor.edit(exact.replacingOccurrences(of: "model: explicit", with: "model: auto"), debounce: false); try await validateCurrentDraft()
        guard editor.issues.contains(where: { $0.code == "model_auto_forbidden" }), !editor.canApply else { throw failure("Auto can apply") }
        editor.edit(exact, debounce: false); try await validateCurrentDraft()
        guard let stage = editor.document.stages.first(where: { $0.id == "dev" }) else { throw failure("Dev stage missing") }
        let fieldPath = "stages[\(stage.index)].name"
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await Task.sleep(for: .milliseconds(500))
        guard let root = window.contentView, let field = descendants(root).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.stringValue == "Dev" }) else { throw failure("Native stage name field missing") }
        window.makeFirstResponder(field)
        try await waitUntil("native pipeline field focus") { field.currentEditor() != nil }
        guard let native = field.currentEditor() as? NSTextView else { throw failure("Field editor missing") }
        native.setSelectedRange(.init(location: 0, length: (native.string as NSString).length))
        native.insertText("Разработка 👋", replacementRange: native.selectedRange()); window.makeFirstResponder(nil)
        try await waitUntil("native field patches exact source") { editor.document.value(fieldPath) == "Разработка 👋" }
        editor.patch("stages[\(stage.index)].wip", value: "1")
        editor.edit(editor.content + "# Native exact draft  👋\n", debounce: false); try await validateCurrentDraft()
        guard editor.canApply, editor.issues.contains(where: { $0.severity == .warning }) else { throw failure("Warning-only source cannot apply") }
        let savedDraft = editor.content
        try (exact + "# external edit\n").write(toFile: source.path, atomically: true, encoding: .utf8)
        await editor.apply()
        guard editor.changedSource != nil, editor.content == savedDraft, editor.submission == nil else { throw failure("Disk race lost draft or submitted") }
        await editor.keepDraftOnChangedSource(); try await validateCurrentDraft()
        guard editor.canApply else { throw failure("Explicit new base unavailable") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(); NSApp.mainMenu?.update()
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36), NSApp.mainMenu?.performKeyEquivalent(with: key) == true else { throw failure("Native Cmd-Return apply route missing") }
        try await waitUntil("real correlated pipelineApplied") { editor.isApplied }
        try await waitUntil("connected after apply") { store.canSend }
        await editor.confirmApplied()
        guard editor.source?.committedContent == savedDraft,
              editor.source?.baseVersionHash == store.projection?.pipelines[project.id]?.versionHash,
              store.projection?.pipelines[project.id]?.stages.first(where: { $0.id == "dev" })?.wip == 1,
              try String(contentsOfFile: source.path, encoding: .utf8) == savedDraft,
              savedDraft.contains("future_extension: preserved"), savedDraft.contains("# preserve this comment") else {
            throw failure("Apply mismatch. exact=\(editor.source?.committedContent == savedDraft), version=\(editor.source?.baseVersionHash ?? "nil") snapshot=\(store.projection?.pipelines[project.id]?.versionHash ?? "nil"), wip=\(store.projection?.pipelines[project.id]?.stages.first(where: { $0.id == "dev" })?.wip ?? -1), error=\(editor.error ?? "none")")
        }
        if AppArguments.value("--export-live-window") != nil { try await captureWindow() }
        return ["real private stdio daemon and actual WindowGroup", "project switch preserves separate unsent drafts and native command owner", "native field edit preserves exact source and unknown fields/comments", "broken YAML and Auto blocked; warnings allow apply", "external write retains draft and requires explicit new base", "native Cmd-Return applies exact text via correlated pipelineApplied", "WIP and version agree with snapshot; daemon commits .kaban/"]
    }
}
#endif
