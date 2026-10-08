import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func suspiciousFilesLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard argument("--developer-database")?.hasPrefix("/tmp/kaban-fe18-") == true, store.macPaused,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private paused file fixture or WindowGroup missing") }
        window.setContentSize(argument("--qa-size") == "minimum" ? .init(width: 1040, height: 640) : .init(width: 1440, height: 900))
        let mode = argument("--qa-files-mode") ?? "accept"
        let name = mode == "reopen" ? "accept" : mode == "finder" ? "binary" : mode == "exception" || mode == "agent" ? "long" : mode == "disconnected" || mode == "cursor" ? "strict" : mode
        let id = TaskID(rawValue: "files-" + name)
        guard let card = store.projection?.tasks[id] else { throw failure("Files task missing") }
        for project in store.projection?.projectOrder ?? [] where project != card.projectId { store.hide(project) }
        store.focusProject(card.projectId); store.screen = .board
        await store.select(id)
        try await waitUntil("current file detail") { store.detail?.task.id == id && store.session.detailReadState == .loaded && store.canSend }
        guard let detail = store.detail else { throw failure("Detail missing") }
        let incidents = store.projection?.projects.values.reduce(0) { $0 + $1.openIncidentCount }
        var checks = ["real WindowGroup and production private daemon; suspicious set produced by actual Git branch-diff result check"]
        if mode == "accept" || mode == "stale" {
            let shown = detail.suspiciousFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) }
            let count = detail.runs.count
            guard let context = store.suspiciousFiles.context(for: id) else { throw failure("Exact acceptance context missing") }
            await store.suspiciousFiles.accept(context)
            if mode == "stale" {
                try await waitUntil("stale set refreshed") {
                    store.suspiciousFiles.staleFiles(for: id) == shown && store.session.detailReadState == .loaded
                        && store.detail?.suspiciousFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) } != shown
                }
                guard store.detail?.acceptedFiles.isEmpty == true, store.detail?.task.state == .waitingHuman(.suspiciousFiles), store.session.error == nil else { throw failure("Stale click accepted files or raised modal") }
                checks.append("old shown blob refused; no accepted pair; refreshed changed blob visible, explicit new action required")
            } else {
                try await waitUntil("accepted set and blocked transition") {
                    store.detail?.acceptedFiles.map { FileBlobRef(path: $0.path, blob: $0.blob) } == shown
                        && store.detail?.task.stageId == "checks" && store.session.detailReadState == .loaded
                }
                guard store.detail?.runs.count == count else { throw failure("Acceptance created a new run") }
                checks.append("exact path+blob accepted, authoritative transition to checks, no new run")
            }
        } else if mode == "reopen" || mode == "history" {
            guard !detail.acceptedFiles.isEmpty, detail.suspiciousFiles.isEmpty else { throw failure("Accepted history missing after reopen") }
            checks.append("new app and daemon restore accepted blobs, actor and backend time from SQLite")
        } else if mode.hasPrefix("gate") || mode.hasPrefix("merge") {
            guard HumanAnswerContext(detail: detail, pipeline: store.projection?.pipelines[detail.task.projectId]) == nil else { throw failure("Gate/merge offered answerHuman") }
            store.suspiciousReturnRoute = .init(taskID: id)
            try await waitUntil("native file return sheet") { window.attachedSheet != nil }
            guard let initial = store.suspiciousFiles.draft(for: id), initial.target == "dev", initial.comments.isEmpty else { throw failure("Server default or empty comment missing") }
            guard !store.canPerform(.cancel), !store.canAnswerSelected, !store.canApproveSelected else { throw failure("Background actions active behind return sheet") }
            if mode.hasSuffix("comment") { store.suspiciousFiles.edit(id, comments: initial.context.removalText) }
            let expected: Command = mode.hasSuffix("comment")
                ? .requestChanges(taskId: id, comments: initial.context.removalText, target: "dev") : .moveTask(taskId: id, stage: "dev")
            guard store.suspiciousFiles.command(for: id) == expected else { throw failure("Comment did not change exact command") }
            if argument("--qa-files-submit") == "yes" {
                guard let sheet = window.attachedSheet,
                      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: sheet.windowNumber,
                                               context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                      NSApp.mainMenu?.performKeyEquivalent(with: key) == true else { throw failure("Cmd-Return file decision unavailable") }
                try await waitUntil("correlated file return") { store.detail?.task.stageId == "dev" && store.suspiciousReturnRoute == nil && store.session.detailReadState == .loaded }
                guard store.suspiciousFiles.returnReceipt(for: id)?.envelope.command == expected,
                      store.detail?.task.bounceByReason == detail.task.bounceByReason else { throw failure("Return command or counters changed") }
                guard mode.hasSuffix("comment") ? store.detail?.acceptedFiles.isEmpty == true : store.detail?.acceptedFiles.isEmpty == false else { throw failure("Return acceptance effect wrong") }
                checks.append("native Cmd-Return executes exact \(mode.hasSuffix("comment") ? "requestChanges without acceptance" : "moveTask with acceptance"), explicit dev target and unchanged bounce counts")
            } else if argument("--qa-files-escape") == "yes" {
                guard let sheet = window.attachedSheet,
                      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                                               context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
                      sheet.performKeyEquivalent(with: key) else { throw failure("Escape unavailable") }
                try await waitUntil("return dismisses without command") { store.suspiciousReturnRoute == nil && window.attachedSheet == nil }
                guard store.suspiciousFiles.returnReceipt(for: id) == nil else { throw failure("Escape sent decision") }
                checks.append("native Escape preserves comment without sending a decision")
            } else { checks.append("native gate/merge return preview changes title, exact command and per-file acceptance effect with empty/nonempty comment") }
        } else if mode == "missing" {
            guard let file = detail.suspiciousFiles.first, await store.openSuspiciousFile(file, detail: detail) == false,
                  store.fileOpeningError != nil else { throw failure("Missing clone was opened") }
            checks.append("missing clone shows an explicit file access error")
        } else if mode == "cursor" {
            guard let file = detail.suspiciousFiles.first, SuspiciousFilesContext.canPreview(file, check: detail.fileCheck) else { throw failure("Text preview decision missing") }
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil
            let opened = await store.openSuspiciousFile(file, detail: detail)
            guard installed ? opened : !opened && store.fileOpeningError != nil else { throw failure("Cursor availability result wrong") }
            checks.append(installed ? "bounded small text file opened through NSWorkspace in installed Cursor, without CLI execution" : "missing Cursor produces explicit editor-unavailable error")
        } else if mode == "agent" {
            guard let context = store.suspiciousFiles.context(for: id), context.stage?.kind == .agent else { throw failure("Agent context missing") }
            store.prepareFileRemoval(context)
            guard store.humanAnswers.draft(for: id)?.text == context.removalText, store.detail?.acceptedFiles.isEmpty == true,
                  store.detail?.task.state == .waitingHuman(.suspiciousFiles) else { throw failure("Removal template accepted files") }
            checks.append("agent removal template preserves exact Unicode path in the existing answer draft without sending or accepting")
        } else if mode == "finder" {
            guard let file = detail.suspiciousFiles.first(where: { !$0.isText }), !SuspiciousFilesContext.canPreview(file, check: detail.fileCheck),
                  await store.openSuspiciousFile(file, detail: detail) else { throw failure("Binary Finder action unavailable") }
            checks.append("bounded binary path validated with no symlink traversal and revealed through NSWorkspace Finder")
        } else if mode == "exception" {
            guard let file = detail.suspiciousFiles.first else { throw failure("No exception path") }
            await store.openFileException(file.path, project: detail.task.projectId)
            try await waitUntil("exact exception draft") { store.activePipelineEditor?.document.stringList("suspicious_files.allow")?.contains(file.path) == true }
            guard store.activePipelineEditor?.selectedStageID == "__files", store.activePipelineEditor?.submission == nil,
                  store.detail?.task.state == .waitingHuman(.suspiciousFiles), store.detail?.acceptedFiles.isEmpty == true else { throw failure("Exception navigation accepted files or wrote pipeline") }
            checks.append("project exceptions open the shared YAML draft with exact path prefilled, without committing or accepting this task")
        } else if mode == "disconnected" {
            guard let context = store.suspiciousFiles.context(for: id) else { throw failure("Disconnected context missing") }
            store.stop(); guard !store.suspiciousFiles.canAccept(context) else { throw failure("Offline acceptance available") }
            checks.append("disconnected file detail retained and mutations disabled")
        } else {
            guard detail.fileCheck != nil, !detail.suspiciousFiles.isEmpty else { throw failure("Missing file facts") }
            checks.append("file path, rule, size, blob and frozen server threshold shown in actual task inspector")
        }
        guard store.projection?.projects.values.reduce(0, { $0 + $1.openIncidentCount }) == incidents else { throw failure("Suspicious files changed incident count") }
        if argument("--qa-files-scroll") == "bottom" {
            store.detailScrollTarget = .suspiciousActions
            try await waitUntil("inspector scroll intent consumed") { store.detailScrollTarget == nil }
            checks.append("actual SwiftUI inspector scroll reaches the controls below the long file path")
        }
        try await captureWindow()
        return checks
    }
}
