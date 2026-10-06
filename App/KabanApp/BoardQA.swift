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
    static var isActive: Bool { argument("--export-live-window") != nil || argument("--ui-smoke") != nil || argument("--qa-window-id") != nil || argument("--daemon-smoke") != nil }
    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func run() async {
        do {
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
            if let path = argument("--daemon-smoke") {
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
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("UI QA failed: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }
    private static func captureWindow() async throws {
        guard let path = argument("--export-live-window") ?? argument("--qa-window-id"),
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("No main window or output path") }
        window.setContentSize(argument("--qa-size") == "minimum" || argument("--qa-state") == "minimum" ? .init(width: 1040, height: 640) : .init(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await Task.sleep(for: .milliseconds(700))
        if argument("--qa-window-id") != nil {
            try Data(String(window.windowNumber).utf8).write(to: URL(fileURLWithPath: path)); return
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
        guard store.projection?.tasks.count == before + 1,
              let record = store.commandJournal?.records.first(where: { if case .createTask = $0.envelope.command { return true }; return false }),
              record.reply?.commandId == record.envelope.commandId, record.reply?.seq != nil,
              record.eventSeq != nil else { throw failure("Command metadata or exactly one creation missing") }
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
    private static func prepare(_ store: BoardStore) async throws {
        switch argument("--qa-state") {
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
        case "hidden": store.visibleIDs = []
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
        // Remount the same WindowGroup subtree so view caching includes unchanged controls.
        // This is export-only; the normal application keeps its existing view identity.
        store.qaLayoutRevision += 1
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
        return checks
    }
    private static func waitUntil(_ state: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let windows = NSApp.windows.map { "\(type(of: $0)) title=\($0.title), visible=\($0.isVisible), key=\($0.isKeyWindow), canKey=\($0.canBecomeKey), main=\($0.isMainWindow), canMain=\($0.canBecomeMain), frame=\($0.frame)" }
        throw failure("Timed out waiting for \(state); projection=\(store?.projection != nil), pendingCreate=\(String(describing: store?.creation.commandID)), created=\(String(describing: store?.createdTaskID)), sheet=\(String(describing: store?.sheet)), search=\(store?.searchRequest ?? -1); runtime=\(runtime?.status ?? "nil"), failure=\(runtime?.failure ?? "nil"), board=\(store?.error ?? "nil"), connection=\(String(describing: store?.connectionState)), active=\(NSApp.isActive), windows=\(windows)")
    }
    private static func failure(_ message: String) -> NSError {
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
