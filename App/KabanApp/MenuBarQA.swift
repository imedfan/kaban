import AppKit
import CoreGraphics
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func menuBarLiveSmoke(_ store: BoardStore) async throws -> [String: Any] {
        guard argument("--developer-database")?.hasPrefix("/tmp/kaban-fe21-") == true,
              let runtime, NSApp.windows.contains(where: { $0.styleMask.contains(.titled) }),
              let project = store.projection?.projectOrder.first else { throw failure("Private FE-21 WindowGroup required") }
        var checks: [String: Any] = ["source": "private stdio daemon; no system notification delivery or registration"]
        store.screen = .board
        store.hide(project)
        guard store.waitingCount == 3, !store.visibleIDs.contains(project) else { throw failure("Hidden project excluded from waiting count") }
        checks["waitingIncludesHiddenProjects"] = true
        for board in NSApp.windows where board.styleMask.contains(.titled) { board.close() }
        try await waitUntil("closed last WindowGroup") { !NSApp.windows.contains { $0.styleMask.contains(.titled) && $0.isVisible } }
        let next = (store.projection?.settings?.maxConcurrentRuns ?? 4) + 1
        store.macSettings.begin(); store.macSettings.editCeiling(String(next))
        guard await store.macSettings.submit(.ceiling) else { throw failure("Closed-window command refused") }
        try await waitUntil("closed-window authoritative event") { store.projection?.settings?.maxConcurrentRuns == next && store.canSend }
        checks["liveUpdatesWithClosedWindow"] = true
        runtime.presentBoard?()
        try await waitUntil("reopened actual WindowGroup") { NSApp.windows.contains { $0.styleMask.contains(.titled) && $0.isVisible } }
        guard store.projection?.settings?.maxConcurrentRuns == next else { throw failure("Reopen lost shared projection") }
        checks["reopenUsesSameProjection"] = true
        let question: TaskID = "answer-question"
        await store.select(question)
        guard let request = store.detail?.humanRequests.last else { throw failure("Current question missing") }
        runtime.notifications.receive(target: .task(projectID: project, taskID: question, requestID: "old-question"), source: store.sourceKey, reply: "Keep this stale reply")
        try await waitUntil("stale notification reply") { runtime.notifications.message != nil }
        guard store.projection?.tasks[question]?.state == .waitingHuman(.question), runtime.notifications.inbox?.reply == "Keep this stale reply",
              store.humanAnswers.receipt(for: question) == nil else { throw failure("Stale notification sent or lost input") }
        checks["staleReplyPreservedWithoutSend"] = true
        runtime.notifications.dismissInbox(); store.error = nil
        let text = "Exact notification reply  \r\n👋"
        runtime.notifications.receive(target: .task(projectID: project, taskID: question, requestID: request.requestId), source: store.sourceKey, reply: text)
        try await waitUntil("notification answer journal event") { store.humanAnswers.receipt(for: question)?.phase == .applied && store.canSend }
        guard store.humanAnswers.record(for: question)?.context.request?.requestId == request.requestId,
              store.humanAnswers.record(for: question)?.text == text,
              store.projection?.tasks[question]?.state == .queued(nil) else { throw failure("Notification reply context/result mismatch") }
        checks["exactReplyConfirmedByEvent"] = true
        runtime.notifications.receive(target: .task(projectID: project, taskID: "deleted-task", requestID: nil), source: store.sourceKey, reply: nil)
        try await waitUntil("deleted notification target") { runtime.notifications.message != nil }
        guard runtime.notifications.message?.contains("удалены") == true else { throw failure("Deleted notification target not explained") }
        checks["deletedTargetExplained"] = true
        runtime.notifications.dismissInbox(); store.error = nil
        store.screen = .board
        guard NSApp.windows.filter({ $0.styleMask.contains(.titled) && $0.canBecomeMain && $0.isVisible }).count == 1 else { throw failure("Notification routes opened duplicate board windows: " + NSApp.windows.filter { $0.styleMask.contains(.titled) }.map { "title=\($0.title), visible=\($0.isVisible), main=\($0.canBecomeMain)" }.joined(separator: "; ")) }
        checks["notificationRoutesReuseBoardWindow"] = true
        try await captureWindow()
        if argument("--qa-menubar-functional") == "YES" {
            checks["actualMenuBarExtraWindow"] = false
            checks["menuBarInspectionGap"] = "Functional run only. Popup, system notification delivery and login acceptance remain unverified."
            return checks
        }
        if let path = argument("--menubar-live-smoke") {
            try JSONSerialization.data(withJSONObject: ["result": "functional_passed_popup_pending", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path + ".functional.json"))
        }
        func statusButton(_ view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            for child in view.subviews { if let found = statusButton(child) { return found } }
            return nil
        }
        if let button = NSApp.windows.compactMap({ $0.contentView.flatMap(statusButton) }).first {
            let visibleWindows = NSApp.windows.filter(\.isVisible).map(\.windowNumber)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: button.bounds.midX, y: button.bounds.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: button.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .init(x: button.bounds.midX, y: button.bounds.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: button.window?.windowNumber ?? 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw failure("Status-button native events unavailable") }
            NSApp.postEvent(up, atStart: true); NSApp.postEvent(down, atStart: true)
            try await Task.sleep(for: .milliseconds(700))
            func openedPopup() -> NSWindow? {
                NSApp.windows.first { $0.isVisible && !visibleWindows.contains($0.windowNumber) && $0.frame.width >= 400 && $0.frame.height > 100 }
            }
            if openedPopup() == nil {
                _ = button.accessibilityPerformPress()
                try await Task.sleep(for: .milliseconds(700))
            }
            let eventAccess = CGPreflightPostEventAccess()
            if openedPopup() == nil, eventAccess, let window = button.window, let screen = window.screen {
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let global = window.convertPoint(toScreen: point)
                let location = CGPoint(x: global.x, y: screen.frame.maxY - global.y)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.postToPid(ProcessInfo.processInfo.processIdentifier)
                }
                try await Task.sleep(for: .milliseconds(700))
            }
            guard let popup = openedPopup(),
                  let view = popup.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  let path = argument("--export-live-window") else { throw failure("MenuBarExtra window not found after status-button action; eventAccess=\(eventAccess), target=\(String(describing: button.target)), action=\(String(describing: button.action)), gestures=\(button.gestureRecognizers). Windows: " + NSApp.windows.map { "\(type(of: $0)) id=\($0.windowNumber) visible=\($0.isVisible) frame=\($0.frame)" }.joined(separator: "; ")) }
            view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("MenuBarExtra PNG unavailable") }
            try png.write(to: URL(fileURLWithPath: path + ".menubar.png"))
            checks["actualMenuBarExtraWindow"] = true
        } else { throw failure("AppKit exposes no NSStatusBarButton; popup acceptance remains unverified") }
        return checks
    }
}
