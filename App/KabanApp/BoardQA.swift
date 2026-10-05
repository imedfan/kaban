import AppKit
import SwiftUI
import KabanProtocol
import KabanBoardCore
import Darwin

/// Opt-in QA of the real WindowGroup. Never runs in a normal launch.
@MainActor enum BoardQA {
    static var store: BoardStore?
    static var isActive: Bool { argument("--export-live-window") != nil || argument("--ui-smoke") != nil || argument("--qa-window-id") != nil }
    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func run() async {
        do {
            try await waitUntil { store?.projection != nil && NSApp.windows.contains { $0.styleMask.contains(.titled) } }
            guard let store else { throw failure("No application store") }
            if let path = argument("--ui-smoke") {
                let checks = try await smoke(store)
                let data = try JSONSerialization.data(withJSONObject: ["result": "passed", "checks": checks], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: path))
            } else if let path = argument("--export-live-window") ?? argument("--qa-window-id") {
                try await prepare(store)
                guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("No main window") }
                if argument("--qa-state") == "minimum" || argument("--qa-size") == "minimum" { window.setContentSize(.init(width: 1040, height: 640)) }
                else { window.setContentSize(.init(width: 1440, height: 900)) }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                // Layout after state, size, colour scheme and presentation changes have settled.
                try await Task.sleep(for: .milliseconds(700))
                if argument("--qa-window-id") != nil {
                    try Data(String(window.windowNumber).utf8).write(to: URL(fileURLWithPath: path))
                    return
                }
                let bitmap = try await ReferenceExport.captureLiveWindow()
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG encoding failed") }
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: url)
            }
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("UI QA failed: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
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
        try await waitUntil { store.createdTaskID != nil && store.creation.commandID == nil }
        guard let id = store.createdTaskID, store.projection?.tasks.count == before + 1 else { throw failure("Creation event missing") }
        await store.select(id)
        guard store.detail?.body == body else { throw failure("Task body was changed") }
        checks.append("create selects task after correlated event and preserves Markdown")
        guard await store.send(.editTask(taskId: id, title: "Edited smoke task", body: body + "\n"), taskID: id) else { throw failure("Edit rejected") }
        try await waitUntil { store.projection?.tasks[id]?.title == "Edited smoke task" && store.projection?.isSent(id) == false }
        guard await store.send(.moveTask(taskId: id, stage: "dev"), taskID: id) else { throw failure("Move rejected") }
        try await waitUntil { store.projection?.tasks[id]?.stageId == "dev" && store.projection?.isSent(id) == false }
        guard await store.send(.cancelTask(taskId: id, keepBranch: false), taskID: id) else { throw failure("Cancel rejected") }
        try await waitUntil { store.projection?.tasks[id]?.state == .cancelled && store.projection?.isSent(id) == false }
        checks.append("edit, move and cancel resolve through typed commands and journal projection")
        guard await store.send(.pauseTask(taskId: "SHOP-42"), taskID: "SHOP-42") else { throw failure("Pause rejected") }
        try await waitUntil { store.projection?.tasks["SHOP-42"]?.state == .paused && store.projection?.isSent("SHOP-42") == false }
        guard await store.send(.resumeTask(taskId: "SHOP-42"), taskID: "SHOP-42") else { throw failure("Resume rejected") }
        try await waitUntil { store.projection?.tasks["SHOP-42"]?.state == .queued(nil) && store.projection?.isSent("SHOP-42") == false }
        checks.append("pause and resume use the client; resume returns queued")
        store.query = "платёж"
        guard store.matches("SHOP-52"), !store.matches("SHOP-58") else { throw failure("Search mismatch") }
        store.query = ""; store.filter = .waiting
        guard store.matches("SHOP-31"), !store.matches("SHOP-58") else { throw failure("Waiting filter mismatch") }
        store.filter = .all
        checks.append("search and attention filters read the same projection")
        for (key, code) in [("n", UInt16(45)), ("f", UInt16(3))] {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code), NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw failure("Keyboard shortcut Cmd-\(key) unavailable") }
        }
        try await waitUntil { store.sheet != nil && store.searchRequest > 0 }
        store.sheet = nil
        checks.append("Cmd-N and Cmd-F invoke the real application menu commands")
        return checks
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw failure("Timed out waiting for UI state")
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BoardQA", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
