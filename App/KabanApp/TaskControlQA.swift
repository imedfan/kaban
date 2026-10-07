import AppKit
import SwiftUI
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func controlSmoke(_ store: BoardStore, requiresFocus: Bool = true) async throws -> [String] {
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Control WindowGroup missing") }
        window.setContentSize(.init(width: 1040, height: 640))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var checks: [String] = []
        func mark(_ text: String) {
            checks.append(text)
            if let path = argument("--control-smoke") ?? argument("--control-routing-smoke") {
                try? checks.joined(separator: "\n").write(toFile: path + ".progress", atomically: true, encoding: .utf8)
            }
        }
        if requiresFocus { try await waitUntil("native control menu focus") { NSApp.isActive && window.isKeyWindow } }
        else { mark("AppKit key-equivalent routing without OS foreground activation; physical keyboard/focus unverified") }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [.command, .shift]) throws {
            func update(_ menu: NSMenu?) { menu?.update(); for item in menu?.items ?? [] { update(item.submenu) } }
            update(NSApp.mainMenu)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              characters: text, charactersIgnoringModifiers: text,
                                              isARepeat: false, keyCode: code),
                  NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw failure("Native task menu shortcut unavailable: \(text)") }
        }
        func sheetKey(_ text: String = "\r", code: UInt16 = 36) async throws {
            try await waitUntil("native task control sheet") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: sheet.windowNumber, context: nil,
                                              characters: text, charactersIgnoringModifiers: text,
                                              isARepeat: false, keyCode: code),
                  sheet.performKeyEquivalent(with: event) else { throw failure("Native control sheet keyboard action missing") }
        }
        func settled(_ id: TaskID, _ predicate: @escaping (TaskCard) -> Bool) async throws {
            try await waitUntil("correlated task control \(id.rawValue)") {
                store.canSend && store.session.pending(in: .task(id)) == nil &&
                store.projection?.tasks[id].map(predicate) == true
            }
            try await waitUntil("dismissed native task control") { window.attachedSheet == nil && store.controlSheet == nil }
        }
        await store.select("SHOP-31")
        try key("p", code: 35)
        try await sheetKey()
        try await settled("SHOP-31") { $0.state == .paused }
        try key("p", code: 35)
        try await sheetKey()
        try await settled("SHOP-31") { $0.state == .waitingHuman(.review) }
        mark("Cmd-Shift-P and Return pause/resume Human Review through the native menu and correlated task events")
        guard store.projection?.tasks["SHOP-42"]?.state == .running else { throw failure("Pausing review changed an unrelated run") }

        await store.toggleMacPause()
        try await waitUntil("Mac flag confirmation") { store.macPaused && store.session.pending(in: .global) == nil && store.canSend }
        await store.toggleProjectPause("shop")
        try await waitUntil("project flag confirmation") { store.projectPaused("shop") && store.session.pending(in: .project("shop")) == nil && store.canSend }
        guard store.projection?.tasks["SHOP-42"]?.state == .running else { throw failure("Global/project pause changed task state") }
        await store.toggleProjectPause("shop")
        try await waitUntil("project resumes before next command") { !store.projectPaused("shop") && store.session.pending(in: .project("shop")) == nil && store.canSend }
        await store.toggleMacPause()
        try await waitUntil("scheduler resumes") { !store.macPaused && !store.projectPaused("shop") && store.session.pendingRecords.isEmpty && store.canSend }
        mark("Mac/project pause updates authoritative flags and clears its own pending without changing current task cards")

        guard let backlog = store.projection?.tasks["SHOP-58"] else { throw failure("Drag source missing") }
        let payload = store.dragItem(backlog)
        guard store.dropTask([payload], project: "shop", stage: "dev"), store.projection?.tasks[backlog.id] == backlog else { throw failure("Drop failed or moved card optimistically") }
        try await sheetKey()
        try await settled(backlog.id) { $0.stageId == "dev" }
        guard !store.dropTask([payload], project: "shop", stage: "backlog"),
              store.session.pending(in: .task(backlog.id)) == nil, store.controlSheet == nil else { throw failure("Stale drag left pending") }
        guard !store.dropTask([store.dragItem(store.projection!.tasks[backlog.id]!)], project: "kaban", stage: "backlog") else { throw failure("Cross-project drag accepted") }
        store.taskDropNotice = nil
        mark("Typed drop handler opens a confirmation without optimistic movement; stale and cross-project payloads send nothing")

        await store.select("SHOP-35")
        try key("r", code: 15); try await sheetKey()
        try await settled("SHOP-35") { $0.state == .queued(nil) }
        mark("Cmd-Shift-R and Return submit a typed retry in an allowed waiting state")

        await store.select("SHOP-42")
        try key("m", code: 46)
        try await waitUntil("move menu opens shared sheet") { store.controlSheet != nil && window.attachedSheet != nil }
        let before = store.projection!.tasks["SHOP-42"]!
        try await sheetKey("\u{1b}", code: 53)
        try await waitUntil("Escape closes move sheet") { store.controlSheet == nil && window.attachedSheet == nil }
        guard store.projection?.tasks["SHOP-42"] == before else { throw failure("Escape sent move") }
        try key("m", code: 46)
        try await waitUntil("focused native move target list") { window.attachedSheet?.firstResponder != nil }
        guard let moveSheet = window.attachedSheet,
              let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: moveSheet.windowNumber, context: nil, characters: "\u{f701}",
                                           charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125) else { throw failure("Native move arrow event missing") }
        moveSheet.sendEvent(arrow)
        try await Task.sleep(for: .milliseconds(250))
        try await sheetKey()
        try await settled("SHOP-42") { $0.stageId == "backlog" }
        mark("Move menu is a keyboard alternative to drag; Escape sends nothing; Down arrow selects an allowed target and Return sends it explicitly")

        await store.select("SHOP-42")
        func deleteEquivalent(_ menu: NSMenu?) -> String? {
            for item in menu?.items ?? [] {
                if item.tag == TaskMenuAction.cancel.rawValue { return item.keyEquivalent }
                if let value = deleteEquivalent(item.submenu) { return value }
            }
            return nil
        }
        guard let delete = deleteEquivalent(NSApp.mainMenu), delete == "\u{8}" || delete == "\u{7f}" else { throw failure("Task cancellation Delete binding missing") }
        try key(delete, code: 51); try await sheetKey()
        try await settled("SHOP-42") { $0.state == .cancelled }
        let cancels = store.commandJournal?.records.filter { if case .cancelTask = $0.envelope.command { true } else { false } } ?? []
        guard cancels.last?.envelope.command == .cancelTask(taskId: "SHOP-42", keepBranch: false) else { throw failure("Cancel default did not preserve keepBranch=false") }
        guard store.canPerform(.cancel) == false else { throw failure("Terminal task can be cancelled again") }
        mark("Cmd-Shift-Delete uses the shared cancellation sheet with keepBranch=false by default")
        return checks
    }

    static func prepareTaskControl(_ store: BoardStore, state: String) async throws -> Bool {
        guard state.hasPrefix("control-") else { return false }
        let suffix = String(state.dropFirst("control-".count))
        let id: TaskID = suffix == "retry" || suffix == "suspicious" ? "SHOP-52" : suffix == "review" ? "SHOP-31" : "SHOP-42"
        guard let card = store.projection?.tasks[id] else { throw failure("Control capture task missing") }
        await store.select(id)
        let action: TaskControlRequest.Action
        switch suffix {
        case "cancel", "cancel-keep", "pending": action = .cancel
        case "retry", "suspicious": action = .retry
        case "review", "pause": action = .pause
        default: action = .move("backlog")
        }
        store.beginControl(card, action: action)
        try await waitUntil("control capture sheet") { NSApp.windows.contains { $0.attachedSheet != nil } }
        if suffix == "pending" {
            Task { _ = await store.send(.cancelTask(taskId: id, keepBranch: false), taskID: id, editor: true) }
            try await waitUntil("delayed control sending") { store.session.pending(in: .task(id)) != nil }
        }
        if suffix == "stale" {
            guard store.usesFixture else { throw failure("Stale mutation is fixture-only") }
            guard await store.send(.pauseTask(taskId: id), taskID: id) else { throw failure("Stale capture pause refused") }
            try await waitUntil("changed authoritative task") { store.projection?.tasks[id]?.state == .paused && store.session.pending(in: .task(id)) == nil }
        }
        if suffix == "error" { store.editorError = String(repeating: "Служба отклонила перенос: задача изменилась. ", count: 4) }
        return true
    }
}

@MainActor final class QADeferredControlClient: KabanClient {
    let base: any KabanClient
    init(base: any KabanClient) { self.base = base }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities { try await base.capabilities() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .cancelTask = envelope.command { try await Task.sleep(for: .seconds(120)) }
        return try await base.send(envelope)
    }
}

extension BoardQA {
    static func controlLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard !store.usesFixture, let repository = argument("--control-live-repository"),
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private live control environment missing") }
        window.setContentSize(.init(width: 1040, height: 640))
        store.projects.open(.add); store.projects.editPath(repository); store.projects.setCreateTemplate(false)
        _ = await store.projects.submit()
        try await waitUntil("live project registration") { store.projects.observeOutcome(); return store.projects.phase == .applied && store.canSend }
        guard let project = store.projection?.projectOrder.first else { throw failure("Live project missing") }
        store.focusProject(project)
        await store.toggleMacPause()
        try await waitUntil("live Mac pause receipt and event") { store.macPaused && store.session.pending(in: .global) == nil && store.canSend }
        await store.toggleProjectPause(project)
        try await waitUntil("live project pause receipt and event") { store.projectPaused(project) && store.session.pending(in: .project(project)) == nil && store.canSend }
        store.prepareCreation()
        await store.create(.init(title: "FE-07 durable controls", description: "Native private daemon controls", acceptanceCriteria: "- Typed task commands"), in: project)
        try await waitUntil("live control task creation") { store.createdTaskID != nil && store.creation.commandID == nil && store.canSend }
        guard let id = store.createdTaskID else { throw failure("Live control task missing") }
        await store.select(id)
        func submit(_ action: TaskMenuAction) async throws {
            store.perform(action)
            try await waitUntil("live native task sheet") { window.attachedSheet != nil && store.controlSheet != nil }
            guard let sheet = window.attachedSheet,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                                              charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                  sheet.performKeyEquivalent(with: event) else { throw failure("Live sheet Return unavailable") }
            try await waitUntil("live sheet dismissal") { window.attachedSheet == nil && store.controlSheet == nil }
        }
        try await submit(.pauseOrResume)
        try await waitUntil("live correlated pause") { store.projection?.tasks[id]?.state == .paused && store.session.pending(in: .task(id)) == nil && store.canSend }
        try await submit(.pauseOrResume)
        try await waitUntil("live correlated resume") { store.projection?.tasks[id]?.state == .queued(nil) && store.session.pending(in: .task(id)) == nil && store.canSend }
        try await submit(.cancel)
        try await waitUntil("live correlated cancel") { store.projection?.tasks[id]?.state == .cancelled && store.session.pending(in: .task(id)) == nil && store.canSend }
        let commands: [ClientCommandJournal.Record] = (store.commandJournal?.records ?? []).filter { record in record.envelope.command.mutationScope == CommandScope.task(id) }
        guard commands.count == 3, commands.allSatisfy({ $0.phase == .applied && $0.eventSeq != nil }),
              commands.last?.envelope.command == .cancelTask(taskId: id, keepBranch: false) else { throw failure("Live task control journal proof missing or duplicate") }
        return ["actual WindowGroup uses a private bundled stdio daemon and SQLite",
                "Mac/project pauses resolve through correlated authoritative scheduler flag events",
                "the shared native sheet Return routes pause/resume/cancel for the selected live task",
                "three exact task commands each have correlated journal event proof; keepBranch defaults to false",
                "scheduler remains paused; no paid Cursor run or installed helper registration"]
    }
}
