import AppKit
import SwiftUI
import KabanProtocol
import KabanBoardCore
import KabanTransport
import Darwin

/// Opt-in QA of the real WindowGroup. Never runs in a normal launch.
@MainActor enum BoardQA {
    static var store: BoardStore?
    static var runtime: DaemonRuntime?
    static var isActive: Bool { ["--files-live-smoke", "--mcp-live-smoke", "--settings-live-smoke", "--model-live-smoke", "--pipeline-live-smoke", "--merge-smoke", "--merge-live-smoke", "--review-smoke", "--review-live-smoke", "--answer-smoke", "--answer-live-smoke", "--log-live-smoke", "--log-volume-smoke", "--log-smoke", "--control-live-smoke", "--control-routing-smoke", "--control-smoke", "--export-live-window", "--ui-smoke", "--qa-window-id", "--daemon-smoke", "--project-smoke", "--task-smoke", "--board-smoke", "--detail-smoke", "--detail-live-smoke"].contains { argument($0) != nil } }
    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func run() async {
        do {
            if argument("--files-live-smoke") != nil || argument("--mcp-live-smoke") != nil || argument("--settings-live-smoke") != nil || argument("--model-live-smoke") != nil || argument("--pipeline-live-smoke") != nil || argument("--review-live-smoke") != nil || argument("--merge-live-smoke") != nil {
                func find(_ menu: NSMenu?) -> NSMenuItem? {
                    for item in menu?.items ?? [] {
                        if item.title == "Открыть окно ревью для проверки" { return item }
                        if let nested = find(item.submenu) { return nested }
                    }
                    return nil
                }
                try await waitUntil("review WindowGroup command") { find(NSApp.mainMenu) != nil }
                guard let item = find(NSApp.mainMenu), let menu = item.menu else { throw failure("WindowGroup command missing") }
                menu.performActionForItem(at: menu.index(of: item))
            }
            if argument("--qa-runtime-state") != nil {
                try await waitUntil("runtime WindowGroup") { NSApp.windows.contains { $0.styleMask.contains(.titled) } }
                if CommandLine.arguments.contains("--qa-incompatible-daemon") {
                    try await waitUntil("protocol rejection") { runtime?.busy == false && runtime?.failure != nil && runtime?.store == nil }
                }
                try await captureWindow()
                if argument("--qa-window-id") != nil { return }
                Darwin.exit(EXIT_SUCCESS)
            }
            try await waitUntil("connected board in WindowGroup") { store?.projection != nil && store?.canSend == true && NSApp.windows.contains { $0.styleMask.contains(.titled) } }
            guard let store else { throw failure("No application store") }
            if let path = argument("--files-live-smoke") {
                let checks = try await suspiciousFilesLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--mcp-live-smoke") {
                let checks = try await projectMCPLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--settings-live-smoke") {
                let checks = try await projectSettingsLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--model-live-smoke") {
                let checks = try await modelLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--pipeline-live-smoke") {
                let checks = try await pipelineLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--merge-live-smoke") {
                let checks = try await mergeLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--merge-smoke") {
                let checks = try await mergeSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--review-live-smoke") {
                let checks = try await reviewLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--review-smoke") {
                let checks = try await reviewSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--answer-live-smoke") {
                let checks = try await answerLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--answer-smoke") {
                let checks = try await answerSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--control-live-smoke") {
                let checks = try await controlLiveSmoke(store)
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--control-smoke") ?? argument("--control-routing-smoke") {
                let checks = try await controlSmoke(store, requiresFocus: argument("--control-routing-smoke") == nil)
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--log-live-smoke") {
                let checks = try await logLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--log-volume-smoke") {
                let checks = try await logVolumeSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--log-smoke") {
                let checks = try await logSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--detail-live-smoke") {
                let checks = try await detailLiveSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--detail-smoke") {
                let checks = try await detailSmoke(store)
                try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--task-smoke") ?? argument("--board-smoke") {
                let checks: [String]
                if argument("--task-smoke") != nil { checks = try await taskSmoke(store) }
                else { checks = try await boardSmoke(store) }
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--project-smoke") {
                let checks = try await projectSmoke(store)
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--daemon-smoke") {
                let checks = try await daemonSmoke(store)
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks, "seq": store.projection?.stateSeq ?? 0], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--ui-smoke") {
                let checks = try await smoke(store)
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--export-live-window") ?? argument("--qa-window-id") {
                try await prepare(store)
                _ = path
                try await captureWindow()
                if argument("--qa-window-id") != nil { return }
            }
            if (argument("--merge-smoke") != nil || argument("--merge-live-smoke") != nil), argument("--export-live-window") != nil {
                try await captureWindow()
            }
            await runtime?.closeDeveloperSession()
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            if let path = ["--files-live-smoke", "--mcp-live-smoke", "--settings-live-smoke", "--model-live-smoke", "--pipeline-live-smoke", "--merge-smoke", "--merge-live-smoke", "--review-smoke", "--review-live-smoke", "--answer-smoke", "--answer-live-smoke", "--log-live-smoke", "--log-smoke", "--log-volume-smoke", "--control-smoke", "--control-routing-smoke", "--control-live-smoke"].compactMap({ argument($0) }).first,
               let data = try? JSONSerialization.data(withJSONObject: ["result": "failed", "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            FileHandle.standardError.write(Data("UI QA failed: \(error)\n".utf8))
            await runtime?.closeDeveloperSession()
            Darwin.exit(EXIT_FAILURE)
        }
    }
    static func captureWindow() async throws {
        guard let path = argument("--export-live-window") ?? argument("--qa-window-id"),
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("No main window or output path") }
        window.setContentSize(argument("--qa-size") == "minimum" || argument("--qa-state") == "minimum" ? .init(width: 1040, height: 640) : .init(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await Task.sleep(for: .milliseconds(700))
        if argument("--qa-state") == "mascot" {
            store?.mascotProjectID = nil
            try await Task.sleep(for: .milliseconds(100))
            store?.mascotProjectID = "shop"
            try await waitUntil("actual mascot popover") {
                NSApp.windows.contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
            }
            guard let popover = NSApp.windows.first(where: { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }),
                  let view = popover.contentView?.superview ?? popover.contentView else { throw failure("Native mascot popover missing") }
            popover.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Native mascot capture unavailable") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Mascot PNG unavailable") }
            try png.write(to: URL(fileURLWithPath: path + ".popover.png"))
        }
        if argument("--qa-window-id") != nil {
            try Data(String(window.windowNumber).utf8).write(to: URL(fileURLWithPath: path)); return
        }
        if argument("--qa-onboarding-scroll") == "bottom", let root = window.contentView {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
            }
            guard let scroll = scrollViews(root).first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height }),
                  let document = scroll.documentView else { throw failure("Onboarding scroll view missing") }
            let y = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: .init(x: 0, y: max(y, 0))); scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(300))
        }
        let bitmap = try await ReferenceExport.captureLiveWindow()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG encoding failed") }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
    private static func daemonSmoke(_ store: BoardStore) async throws -> [String] {
        try await waitUntil("daemon connection") { store.canSend }
        guard let project = store.projection?.projectOrder.first else { throw failure("Live project missing") }
        if CommandLine.arguments.contains("--daemon-smoke-reopen") {
            guard let card = store.projection?.tasks.values.first(where: { $0.title == "Edited durable task" && $0.state == .cancelled }) else { throw failure("Durable task missing after reopening") }
            await store.select(card.id)
            guard store.detail?.body == "Durable body\n" else { throw failure("Durable body missing after reopening") }
            return ["reopened embedded daemon restores task, body and journal without fixtures"]
        }
        store.prepareCreation()
        let before = store.projection?.tasks.count ?? 0
        await store.create(.init(title: "Durable UI task", body: "Durable body"), in: project)
        try await waitUntil("correlated task creation") { store.createdTaskID != nil && store.creation.commandID == nil && store.canSend }
        guard let id = store.createdTaskID else { throw failure("Correlated creation missing") }
        let records = store.commandJournal?.records.filter { if case .createTask = $0.envelope.command { return true }; return false } ?? []
        guard records.count == 1, let record = records.first else { throw failure("Exactly one create intent was not retained") }
        let eventProof = record.createdTaskID == id && (record.confirmedSeq ?? 0) > 0 && record.eventSeq != nil
        let receiptTaskID: TaskID?
        if case .taskCreated(let value) = record.reply?.result { receiptTaskID = value } else { receiptTaskID = nil }
        let snapshotProof = receiptTaskID == id && record.reply?.commandId == record.envelope.commandId &&
            (record.reply?.seq ?? 0) > 0 && (record.coveredSnapshotSeq ?? -1) >= (record.reply?.seq ?? 0) &&
            (record.coveredSnapshotSeq ?? -1) <= (store.projection?.stateSeq ?? -1)
        // A lost reply may be proven by the typed event alone. Retention may
        // instead require the original typed receipt plus applied snapshot.
        // Acceptance alone never satisfies either proof.
        guard store.projection?.tasks.count == before + 1, record.phase == .applied,
              record.envelope.command == .createTask(projectId: project, title: "Durable UI task", body: "Durable body"),
              store.projection?.tasks[id]?.projectId == project,
              record.reply == nil || record.reply?.commandId == record.envelope.commandId,
              eventProof || snapshotProof else {
            throw failure("Creation proof missing: before=\(before), after=\(store.projection?.tasks.count ?? -1), phase=\(record.phase), receiptSeq=\(String(describing: record.reply?.seq)), eventSeq=\(String(describing: record.eventSeq)), confirmedSeq=\(String(describing: record.confirmedSeq)), coveredSnapshotSeq=\(String(describing: record.coveredSnapshotSeq)), eventProof=\(eventProof), snapshotProof=\(snapshotProof)")
        }
        guard store.capabilities?.supportsOperation("readLog") == true else { throw failure("Log capability missing") }
        do { _ = try await store.readLog(runId: "missing-qa-run", fromOffset: 0); throw failure("Missing log became empty success") }
        catch let error as CommandError { guard error.code != CommandError.unsupportedOperationCode else { throw failure("Log API was not forwarded") } }
        do {
            for try await _ in store.tailLog(runId: "missing-qa-run", fromOffset: 0) { throw failure("Missing tail became log records") }
            throw failure("Missing tail became empty success")
        } catch let error as CommandError { guard error.code != CommandError.unsupportedOperationCode else { throw failure("Tail API was not forwarded") } }
        guard await store.send(.editTask(taskId: id, title: "Edited durable task", body: "Durable body\n"), taskID: id) else { throw failure("Live edit rejected") }
        try await waitUntil("durable task edit") { store.projection?.tasks[id]?.title == "Edited durable task" && store.projection?.isSent(id) == false && store.canSend }
        guard await store.send(.pauseTask(taskId: id), taskID: id) else { throw failure("Live pause rejected") }
        try await waitUntil("task pause") { store.projection?.tasks[id]?.state == .paused && store.projection?.isSent(id) == false && store.canSend }
        guard await store.send(.resumeTask(taskId: id), taskID: id) else { throw failure("Live resume rejected") }
        try await waitUntil("task resume") { store.projection?.tasks[id]?.state.status == .queued && store.projection?.isSent(id) == false && store.canSend }
        guard await store.send(.cancelTask(taskId: id, keepBranch: false), taskID: id) else { throw failure("Live cancel rejected") }
        try await waitUntil("task cancellation") { store.projection?.tasks[id]?.state == .cancelled && store.projection?.isSent(id) == false && store.canSend }
        await store.select(id)
        guard store.detail?.body == "Durable body\n" else { throw failure("Live body changed") }
        if let path = argument("--daemon-smoke-window") {
            if argument("--qa-size") == "minimum" { NSApp.windows.first { $0.styleMask.contains(.titled) }?.setContentSize(.init(width: 1040, height: 640)) }
            try await Task.sleep(for: .milliseconds(700))
            let bitmap = try await ReferenceExport.captureLiveWindow()
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG encoding failed") }
            try png.write(to: URL(fileURLWithPath: path))
        }
        return ["real WindowGroup uses the bundled stdio daemon", "create, edit, pause, resume and cancel complete through correlated journal events", "command envelope and receipt metadata are retained; lost create reply does not duplicate the task", "capabilities, readLog and tailLog use the same daemon session", "task body remains durable; no paid agent is launched"]
    }
    private static func projectSmoke(_ initial: BoardStore) async throws -> [String] {
        guard !initial.usesFixture, let repository = argument("--project-smoke-repository"), let relocated = argument("--project-smoke-relink"), let runtime else { throw failure("Real project smoke configuration missing") }
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.contentView != nil }) else { throw failure("Project WindowGroup missing") }
        let before = initial.projection?.projects.count ?? 0
        initial.beginProjectFlow(.add)
        try await waitUntil("actual AddProject sheet") { window.attachedSheet != nil }
        initial.projects.setCreateTemplate(false)
        var enteredIdentity: GitIdentity?
        if let nonGit = argument("--project-smoke-non-git") {
            initial.projects.editPath(nonGit); _ = await initial.projects.submit()
            try await waitUntil("real non-git refusal") { if case .rejected(let error) = initial.projects.phase { return error.code == "not_git_repository" && initial.canSend }; return false }
            guard initial.projection?.projects.count == before, initial.projects.draft.path == nonGit, !initial.projects.draft.createTemplate else { throw failure("Non-git refusal lost input or registered a lane") }
            initial.projects.editPath(repository); _ = await initial.projects.submit()
            try await waitUntil("real git identity refusal") { if case .rejected(let error) = initial.projects.phase { return error.code == "identity_required" && initial.canSend }; return false }
            guard initial.projection?.projects.count == before, initial.projects.draft.identity.focus == .name,
                  initial.projects.draft.identity.name.caption != nil, !initial.projects.draft.identity.name.highlighted else { throw failure("First invalid identity rendering does not follow server params") }
            initial.projects.editIdentity(.name, value: "\n"); initial.projects.editIdentity(.email, value: " ")
            _ = await initial.projects.submit()
            try await waitUntil("real repeated identity refusal") { if case .rejected(let error) = initial.projects.phase { return error.code == "identity_required" && error.params["invalid"] == "name" && error.params["missing"] == "email" && initial.canSend }; return false }
            guard initial.projection?.projects.count == before, initial.projects.draft.identity.name.highlighted,
                  initial.projects.draft.identity.email.highlighted, initial.projects.draft.path == repository,
                  !initial.projects.draft.createTemplate else { throw failure("Repeated identity refusal lost input or created a lane") }
            let identity = GitIdentity(name: "Kaban Project QA", email: "project-qa@example.test")
            enteredIdentity = identity
            initial.projects.editIdentity(.name, value: identity.name); initial.projects.editIdentity(.email, value: identity.email)
        } else { initial.projects.editPath(repository) }
        _ = await initial.projects.submit()
        try await waitUntil("correlated project registration") { initial.projects.observeOutcome(); return initial.projects.phase == .applied && initial.projects.connectedProjectID != nil && initial.canSend }
        let id = initial.projects.connectedProjectID!
        guard initial.projection?.projects.count == before + 1,
              let record = initial.projects.record, record.confirmedSeq != nil,
              record.envelope.command == .addProject(path: repository, createTemplate: false, identity: enteredIdentity),
              initial.projection?.projects[id]?.path == URL(fileURLWithPath: repository).standardizedFileURL.path else { throw failure("Project registration proof missing: \(String(describing: initial.projects.record))") }
        // A catch-up replacement can cover committed projectAdded before its
        // individual delivery. The original receipt plus that authoritative
        // snapshot proves recovery; acceptance alone fails this assertion.
        let eventProof = record.createdProjectID == id && record.eventSeq != nil
        let receiptProof: Bool
        if let reply = record.reply, reply.commandId == record.envelope.commandId, reply.result == .ok,
           let seq = reply.seq, seq > 0, let covered = record.coveredSnapshotSeq, covered >= seq,
           (initial.projection?.stateSeq ?? 0) >= covered { receiptProof = true }
        else { receiptProof = false }
        guard eventProof || receiptProof else { throw failure("Project lacks correlated event or covered original receipt") }
        try await waitUntil("one new board lane") { initial.visibleIDs.filter { $0 == id }.count == 1 }
        await initial.projects.refreshDiagnostics()
        try await waitUntil("completed server project diagnostics") { !initial.projects.isReading && initial.projects.branches != nil && initial.projects.gates != nil && initial.projects.environmentError != nil }
        guard initial.projects.branches?.contains("main") == true, initial.projects.gates != nil, initial.projects.environment == nil, initial.projects.environmentError != nil else { throw failure("Project diagnostics lost authoritative/unknown distinction") }
        if argument("--project-smoke-non-git") != nil, initial.projectCaption(id) != "Пайплайн не настроен" { throw failure("no_pipeline caption does not reflect server validation") }
        if argument("--export-live-window") != nil { try await captureWindow() }
        initial.projectSheet = nil; initial.selectedProjectID = id
        try await waitUntil("closed AddProject sheet") { window.attachedSheet == nil }
        initial.beginCreation(id)
        try await waitUntil("Backlog creation sheet") { window.attachedSheet != nil }
        await initial.create(.init(title: "Project lifecycle smoke task", body: "Backlog without valid pipeline"), in: id)
        try await waitUntil("project Backlog creation") { initial.createdTaskID != nil && initial.canSend }
        let taskID = initial.createdTaskID!
        initial.sheet = nil
        try await waitUntil("closed task sheet") { window.attachedSheet == nil }
        await runtime.retry()
        try await waitUntil("reopened project database") { runtime.store !== initial && runtime.store?.canSend == true }
        guard let store = runtime.store, store.projection?.projects[id]?.path == repository, store.projection?.tasks[taskID]?.projectId == id else { throw failure("Project or task lost on reopen") }
        store.beginProjectFlow(.relink(id))
        try await waitUntil("actual relink sheet") { window.attachedSheet != nil }
        store.projects.editPath(relocated); _ = await store.projects.submit()
        try await waitUntil("correlated project relink") { store.projects.observeOutcome(); return store.projects.phase == .applied && store.projection?.projects[id]?.path == relocated && store.canSend }
        guard store.projection?.tasks[taskID]?.projectId == id else { throw failure("Relink changed task identity") }
        store.projectSheet = nil; store.screen = .project(id)
        try await waitUntil("closed relink sheet") { window.attachedSheet == nil }
        store.beginProjectFlow(.remove(id))
        try await waitUntil("actual removal confirmation") { window.attachedSheet != nil }
        _ = await store.projects.submit()
        try await waitUntil("correlated project removal") { store.projects.observeOutcome(); return store.projects.phase == .applied && store.projection?.projects[id] == nil && store.canSend && store.screen == .board }
        guard !store.visibleIDs.contains(id), FileManager.default.fileExists(atPath: repository + "/.git"), FileManager.default.fileExists(atPath: relocated + "/.git") else { throw failure("Removal changed user repository or left lane") }
        return ["actual WindowGroup and Add/Relink/Remove sheets", "project appears after correlated event or covered receipt and gets one lane", "server branch/gates reads and unknown environment", "Backlog task with invalid/missing pipeline", "real private DB reopens with project and task IDs", "relink keeps project/task IDs", "remove updates selection and leaves both repositories on disk"]
    }
    private static func prepare(_ store: BoardStore) async throws {
        if try await prepareMerge(store) { return }
        if try await prepareReview(store) { return }
        if try await prepareAnswer(store) { return }
        if try await prepareRunHistory(store) { return }
        if try await prepareDetails(store) { return }
        if try await prepareTaskEditor(store) { return }
        if let state = argument("--qa-state"), try await prepareTaskControl(store, state: state) { return }
        switch argument("--qa-state") {
        case "grouped": store.compactBoard = true
        case "hidden-stages": store.filter = .hiddenStages
        case "hidden-project": store.hide("shop")
        case "mascot": store.mascotProjectID = "shop"
        case "details": await store.select("SHOP-52")
        case "review": await store.select("SHOP-31")
        case "project": store.screen = .project("shop")
        case "quota": store.screen = .quota
        case "create": store.beginCreation("shop")
        case "move": if let card = store.projection?.tasks["SHOP-42"] { store.sheet = .move(card) }
        case "cancel": if let card = store.projection?.tasks["SHOP-42"] { store.sheet = .cancel(card) }
        case "edit": await store.select("SHOP-58"); if let detail = store.detail { store.sheet = .edit(detail.task, detail.body) }
        case "search": store.query = "платёж"
        case "no-results": store.query = "нет такой задачи"
        case "hidden": for id in store.visibleIDs { store.hide(id) }
        case "error": store.error = "Не удалось связаться с источником состояния. Попробуйте ещё раз."
        case "reconnecting": store.connectionState = .reconnecting(lastSeq: store.projection?.stateSeq)
        case "connection-error": store.connectionState = .disconnected(.init(code: "reconciliation_failed", message: "Не удалось проверить сохранённые отправки. Служба временно недоступна; задачи и черновики сохранены. Проверьте подключение снова."))
        case "pending-create":
            let draft = DemoTaskDraft(title: "Сохранённый черновик с длинным заголовком и точным Markdown", description: "## Описание\n\nТекст остаётся в форме после разрыва связи. **Проверяем исходную отправку**; второе создание заблокировано.\n", acceptanceCriteria: "- Одна задача после восстановления связи.\n- Текст сохранён буквально.")
            try store.session.drafts?.save(.init(key: .create("shop"), draft: draft))
            let envelope = CommandEnvelope(command: .createTask(projectId: "shop", title: draft.title, body: draft.body))
            try store.commandJournal?.begin(envelope); try store.commandJournal?.markUncertain(envelope.commandId)
            store.connectionState = .reconnecting(lastSeq: store.projection?.stateSeq); store.sheet = .create("shop")
        default: break
        }
        if let state = argument("--qa-project-form") {
            if state == "remove" { store.beginProjectFlow(.remove("shop")) }
            else if state == "relink" { store.beginProjectFlow(.relink("shop")) }
            else {
                store.beginProjectFlow(.add)
                store.projects.editPath("/Users/local/Projects/Очень длинное название выбранного репозитория/shop-api")
                if state != "add" { _ = await store.projects.submit(); store.projects.observeOutcome() }
                if state == "repeat" {
                    store.projects.editIdentity(.email, value: " ")
                    _ = await store.projects.submit(); store.projects.observeOutcome()
                }
            }
        }
        // Remount the same WindowGroup subtree so view caching includes unchanged controls.
        // This is export-only; the normal application keeps its existing view identity.
        store.qaLayoutRevision += 1
    }
    private static func boardSmoke(_ store: BoardStore) async throws -> [String] {
        guard store.usesFixture else { throw failure("Board smoke requires explicit DTO fixtures") }
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("No actual board WindowGroup") }
        window.makeKeyAndOrderFront(nil)
        if argument("--qa-board-restart") == "verify" {
            guard store.visibleIDs == ["docs", "kaban", "mobile"], store.projection?.projects["shop"] != nil,
                  (store.projection?.badgeCounts(for: "shop").waitingHuman ?? 0) > 0,
                  store.projection?.projects["shop"]?.openIncidentCount == 1,
                  store.projection?.tasks["SHOP-42"]?.state == .running else { throw failure("BoardSet did not survive an actual process restart") }
            return ["Actual application process restart restored hidden shop and lane order docs/kaban/mobile; waiting/incident badges and task state remain authoritative"]
        }
        let initialIDs = store.visibleIDs, initialTasks = store.projection?.tasks, initialSeq = store.projection?.stateSeq
        guard initialIDs.count >= 2 else { throw failure("Board fixture lacks projects") }
        var checks: [String] = []
        guard let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19), NSApp.mainMenu?.performKeyEquivalent(with: shortcut) == true else { throw failure("Cmd-2 project menu missing") }
        try await waitUntil("native project shortcut") { store.selectedProjectID == initialIDs[1] && store.focusRequest > 0 }
        checks.append("Cmd-2 focuses a visible project through the real native menu")
        guard let reorder = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f700}", charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126), NSApp.mainMenu?.performKeyEquivalent(with: reorder) == true else { throw failure("Cmd-Option-Up project menu missing") }
        try await waitUntil("native lane reorder shortcut") { store.visibleIDs.first == initialIDs[1] }
        checks.append("Cmd-Option-Up reorders the project through the real native menu")
        guard store.visibleIDs.first == initialIDs[1] else { throw failure("Project order unchanged") }
        store.hide(initialIDs[0])
        guard store.projection?.tasks == initialTasks, store.projection?.stateSeq == initialSeq else { throw failure("Local board operation mutated daemon state") }
        let badges = store.projection?.badgeCounts(for: initialIDs[0])
        guard (badges?.waitingHuman ?? 0) > 0 else { throw failure("Hidden project lost waiting badge") }
        checks.append("Hide and reorder preserve all task state and the waiting badge without a daemon mutation")
        guard store.dropProject(["kaban-project:" + initialIDs[0].rawValue], before: initialIDs[1]), store.visibleIDs.first == initialIDs[0],
              !store.dropProject(["foreign"], before: nil) else { throw failure("Project drop handler failed") }
        checks.append("The same drop handler used by SwiftUI restores a hidden project; foreign payload is rejected")
        for (index, id) in initialIDs.enumerated() { store.session.move(id, to: index) }
        let before = store.projection?.projects["shop"]?.mascotSeed
        await store.setMascot("shop", index: 2, texture: .waves)
        try await waitUntil("correlated mascot update") { store.projection?.projects["shop"]?.mascotSeed != before && store.pendingLabel(.project("shop")) == nil }
        guard MascotKit.pick(seed: store.projection?.projects["shop"]?.mascotSeed ?? "").texture == .waves else { throw failure("Mascot seed did not confirm the selected texture") }
        checks.append("Mascot choice is applied through setMascot and the correlated projectUpdated event")
        store.compactBoard = true
        try await Task.sleep(for: .milliseconds(200))
        guard store.projection?.tasks == initialTasks else { throw failure("Compact board mutated task state") }
        checks.append("Compact view and local board changes render in the actual WindowGroup")
        if argument("--qa-board-restart") == "seed" {
            store.hide("shop"); store.session.move("docs", to: 0)
            guard store.visibleIDs == ["docs", "kaban", "mobile"] else { throw failure("Restart seed order wrong") }
            checks.append("Separate QA UserDefaults suite persisted hidden shop and reordered docs for a new application process")
        }
        return checks
    }
    private static func smoke(_ store: BoardStore) async throws -> [String] {
        var checks: [String] = []
        guard NSApp.windows.contains(where: { $0.styleMask.contains(.titled) && $0.contentView != nil }) else { throw failure("WindowGroup missing") }
        checks.append("real application WindowGroup is mounted")
        let before = store.projection?.tasks.count ?? 0
        store.prepareCreation()
        let body = "## Описание\n\nSmoke content\n\n## Критерии приёмки\n\n- Текст сохраняется."
        await store.create(.init(title: "UI smoke task", body: body), in: "shop")
        try await waitUntil("correlated task creation") { store.createdTaskID != nil && store.creation.commandID == nil && store.canSend }
        guard let id = store.createdTaskID, store.projection?.tasks.count == before + 1 else { throw failure("Creation event missing") }
        await store.select(id)
        guard store.detail?.body == body else { throw failure("Task body was changed") }
        checks.append("create selects task after correlated event and preserves Markdown")
        guard await store.send(.editTask(taskId: id, title: "Edited smoke task", body: body + "\n"), taskID: id) else { throw failure("Edit rejected") }
        try await waitUntil("task edit") { store.projection?.tasks[id]?.title == "Edited smoke task" && store.projection?.isSent(id) == false && store.canSend }
        guard await store.send(.moveTask(taskId: id, stage: "dev"), taskID: id) else { throw failure("Move rejected") }
        try await waitUntil("task move") { store.projection?.tasks[id]?.stageId == "dev" && store.projection?.isSent(id) == false && store.canSend }
        guard await store.send(.cancelTask(taskId: id, keepBranch: false), taskID: id) else { throw failure("Cancel rejected") }
        try await waitUntil("task cancellation") { store.projection?.tasks[id]?.state == .cancelled && store.projection?.isSent(id) == false && store.canSend }
        checks.append("edit, move and cancel resolve through typed commands and journal projection")
        guard await store.send(.pauseTask(taskId: "SHOP-42"), taskID: "SHOP-42") else { throw failure("Pause rejected") }
        try await waitUntil("fixture task pause") { store.projection?.tasks["SHOP-42"]?.state == .paused && store.projection?.isSent("SHOP-42") == false && store.canSend }
        guard await store.send(.resumeTask(taskId: "SHOP-42"), taskID: "SHOP-42") else { throw failure("Resume rejected") }
        try await waitUntil("fixture task resume") { store.projection?.tasks["SHOP-42"]?.state == .queued(nil) && store.projection?.isSent("SHOP-42") == false && store.canSend }
        checks.append("pause and resume use the client; resume returns queued")
        store.query = "платёж"
        guard store.matches("SHOP-52"), !store.matches("SHOP-58") else { throw failure("Search mismatch") }
        store.query = ""; store.filter = .waiting
        guard store.matches("SHOP-31"), !store.matches("SHOP-58") else { throw failure("Waiting filter mismatch") }
        store.filter = .all
        checks.append("search and attention filters read the same projection")
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.contentView != nil }) else { throw failure("Keyboard window missing") }
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await waitUntil("keyboard window focus") { NSApp.isActive && window.isKeyWindow }
        func creationMenuEnabled(_ menu: NSMenu?) -> Bool {
            menu?.update()
            return (menu?.items ?? []).contains { item in
                (item.title == "Новая задача" && item.keyEquivalent == "n" && item.isEnabled) || creationMenuEnabled(item.submenu)
            }
        }
        try await waitUntil("New task menu availability") { creationMenuEnabled(NSApp.mainMenu) }
        store.connectionState = .reconnecting(lastSeq: store.projection?.stateSeq)
        try await waitUntil("New task menu disabled while reconnecting") { !creationMenuEnabled(NSApp.mainMenu) }
        store.connectionState = .connected
        try await waitUntil("New task menu reenabled after connection") { creationMenuEnabled(NSApp.mainMenu) }
        for (key, code) in [("n", UInt16(45)), ("f", UInt16(3))] {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code), NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw failure("Keyboard shortcut Cmd-\(key) unavailable") }
        }
        try await waitUntil("menu shortcuts") { store.sheet != nil && store.searchRequest > 0 }
        store.sheet = nil
        checks.append("Cmd-N and Cmd-F invoke the real application menu commands")
        if argument("--qa-project-form") != nil {
            try await projectKeyboardSmoke(store)
            checks.append("AddProject Return submits, refusal focuses missing email; Escape closes and reopening preserves input")
        }
        return checks
    }
    private static func projectKeyboardSmoke(_ store: BoardStore) async throws {
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.contentView != nil }) else { throw failure("Project keyboard window missing") }
        try await waitUntil("closed previous keyboard sheet") { window.attachedSheet == nil }
        store.beginProjectFlow(.add)
        store.projects.editPath("/chosen/project-keyboard"); store.projects.setCreateTemplate(false)
        try await waitUntil("AddProject keyboard sheet") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        sheet.makeKeyAndOrderFront(nil); NSApp.activate()
        try await waitUntil("AddProject key focus") { sheet.isKeyWindow }
        func key(_ text: String, code: UInt16) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code), sheet.performKeyEquivalent(with: event) else { throw failure("Project sheet keyboard action unavailable") }
        }
        try key("\r", code: 36)
        try await waitUntil("AddProject keyboard refusal") { if case .rejected = store.projects.phase { return true }; return false }
        guard store.projects.draft.path == "/chosen/project-keyboard", !store.projects.draft.createTemplate,
              store.projects.draft.identity.focus == .email else { throw failure("Refusal lost input or focus target") }
        try await waitUntil("missing email native field focus") { (sheet.firstResponder as? NSTextView)?.string == "" }
        try key("\u{1b}", code: 53)
        try await waitUntil("Escape closes AddProject") { window.attachedSheet == nil && store.projectSheet == nil }
        store.beginProjectFlow(.add)
        try await waitUntil("reopened AddProject") { window.attachedSheet != nil }
        guard store.projects.draft.path == "/chosen/project-keyboard", !store.projects.draft.createTemplate,
              store.projects.draft.identity.name.value == "Автор проекта", store.projects.draft.showsIdentity else { throw failure("Project draft lost after keyboard dismissal") }
        store.projectSheet = nil
        try await waitUntil("project keyboard sheet cleanup") { window.attachedSheet == nil }
    }
    static func waitUntil(_ state: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let windows = NSApp.windows.map { "\(type(of: $0)) title=\($0.title), visible=\($0.isVisible), key=\($0.isKeyWindow), canKey=\($0.canBecomeKey), main=\($0.isMainWindow), canMain=\($0.canBecomeMain), frame=\($0.frame)" }
        throw failure("Timed out waiting for \(state); projection=\(store?.projection != nil), pendingCreate=\(String(describing: store?.creation.commandID)), created=\(String(describing: store?.createdTaskID)), sheet=\(String(describing: store?.sheet)), search=\(store?.searchRequest ?? -1); runtime=\(runtime?.status ?? "nil"), failure=\(runtime?.failure ?? "nil"), board=\(store?.error ?? "nil"), connection=\(String(describing: store?.connectionState)), active=\(NSApp.isActive), windows=\(windows)")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "BoardQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Opt-in fault injection after a real daemon commit, before the adapter sees its reply.
actor QAReplyLossTransport: DaemonTransport {
    let base: any DaemonTransport
    private var dropped = false
    init(base: any DaemonTransport) { self.base = base }
    func exchange(_ request: DaemonRequest) async throws -> DaemonResponse {
        let response = try await base.exchange(request)
        if case .command(let envelope) = request.operation, case .createTask = envelope.command, !dropped {
            dropped = true; throw DaemonTransportError.connectionLost
        }
        return response
    }
}

/// Exercises the actual runtime's protocol rejection against an isolated helper.
struct QAIncompatibleTransport: DaemonTransport {
    let base: any DaemonTransport
    func exchange(_ request: DaemonRequest) async throws -> DaemonResponse {
        var response = try await base.exchange(request)
        if case .capabilities = request.operation { response.protocolVersion += 1 }
        return response
    }
}
