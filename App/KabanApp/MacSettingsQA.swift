#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func cursorEnvironmentLiveSmoke(_ store: BoardStore) async throws -> [String: Any] {
        guard let database = AppArguments.value("--developer-database"), database.hasPrefix("/tmp/kaban-fe23-") else {
            throw failure("Private FE-23 database required")
        }
        let mode = AppArguments.value("--qa-cursor-mode") ?? "missing"
        let root = URL(fileURLWithPath: database).deletingLastPathComponent()
        let executable = root.appendingPathComponent("Очень длинный каталог Cursor CLI с пробелами/bin/cursor-agent").path
        if AppArguments.value("--qa-onboarding") == nil { runtime?.finishSetup(); store.screen = .quota }
        let environment = store.environment
        await environment.refresh()
        try await waitUntil("environment read") { !environment.isChecking }
        guard environment.report != nil, environment.configuration != nil else { throw failure("Environment reads missing") }
        if ["configure", "invalid", "not-runnable", "logged-out"].contains(mode) {
            let chosen = mode == "invalid" ? "relative/path" : executable
            environment.editPath(chosen)
            let saved = await environment.savePath()
            if mode == "invalid" {
                guard !saved, case .rejected = environment.submissionPhase,
                      environment.draftPath == chosen, environment.canConfigure else { throw failure("Invalid path refusal lost draft or blocked correction") }
            } else {
                guard saved else { throw failure("Configuration refused") }
                try await waitUntil("cursorEnvironmentChanged") { environment.submissionPhase == .applied && store.canSend }
                await environment.refresh()
                try await waitUntil("confirmed environment read") { !environment.isChecking }
                guard environment.configuration?.executablePath == executable, !environment.isEdited,
                      let id = environment.submittedCommandID,
                      let record = store.commandJournal?.records.first(where: { $0.envelope.commandId == id }),
                      (record.confirmedSeq ?? 0) > 0 else {
                    throw failure("Path not confirmed: configuration=\(String(describing: environment.configuration)), edited=\(environment.isEdited), receipt=\(String(describing: store.commandJournal?.records.last))")
                }
            }
        } else if mode == "recheck" {
            guard environment.runnerReason == .agentNotLoggedIn else { throw failure("Recovery must start logged out") }
            try Data("ready".utf8).write(to: root.appendingPathComponent("mode"))
            guard await environment.recheck() else { throw failure("Runner recheck refused") }
            try await waitUntil("runner recovery") { store.canSend && environment.runnerReason == nil }
            await environment.refresh()
        }
        try await waitUntil("latest environment report") { !environment.isChecking }
        let expected: RunnerUnavailableReason?
        switch mode {
        case "missing", "invalid": expected = .agentMissing
        case "not-runnable": expected = .agentNotRunnable
        case "logged-out": expected = .agentNotLoggedIn
        default: expected = nil
        }
        guard environment.runnerReason == expected else { throw failure("Wrong runner reason: \(String(describing: environment.runnerReason))") }
        if ["configure", "restart", "recheck", "picker"].contains(mode) {
            guard environment.report?.authOK == true, environment.report?.version == "fixture-fe23-1.0",
                  environment.configuration?.executablePath == executable,
                  store.models.catalog.contains(where: { $0.id.rawValue == "fixture-model" && ModelSelection.selectable($0, flags: store.models.flags) }) else {
                throw failure("Configured facts missing: report=\(String(describing: environment.report)), configuration=\(String(describing: environment.configuration)), catalog=\(store.models.catalog)")
            }
        }
        if mode == "offline" {
            environment.editPath("/unsent/cursor-agent")
            await runtime?.closeDeveloperSession()
            guard environment.isStale, !environment.canConfigure, environment.draftPath == "/unsent/cursor-agent" else {
                throw failure("Offline draft or stale state wrong")
            }
        }
        if mode == "picker" {
            let path = root.appendingPathComponent("repo").path
            if !store.macPaused {
                _ = await store.session.send(.pauseAll)
                try await waitUntil("paused Mac") { store.macPaused && store.canSend }
            }
            _ = await store.session.send(.addProject(path: path, createTemplate: false, identity: .init(name: "Cursor QA", email: "cursor@example.test")))
            try await waitUntil("picker project") { store.canSend && store.projection?.projects.values.contains { $0.path == path } == true }
            guard let project = store.projection?.projects.values.first(where: { $0.path == path }) else { throw failure("Picker project missing") }
            let editor = store.pipelineEditor(for: project.id)
            await editor.loadIfNeeded()
            store.openPipelineIssues(project.id)
            try await waitUntil("model picker popover") { NSApp.windows.contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") } }
            guard let popover = NSApp.windows.first(where: { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }),
                  let view = popover.contentView?.superview ?? popover.contentView,
                  let capture = AppArguments.value("--export-live-window") else { throw failure("Model picker missing") }
            popover.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Picker bitmap missing") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Picker PNG missing") }
            try png.write(to: URL(fileURLWithPath: capture + ".popover.png"))
        }
        try await captureWindow()
        return ["mode": mode, "privateDaemon": true, "report": true, "reason": expected?.rawValue ?? "none",
                "configurationCommandID": environment.submittedCommandID?.uuidString ?? "",
                "selectableCatalog": store.models.catalog.contains { $0.id.rawValue == "fixture-model" },
                "installedServiceVerified": false]
    }
    static func macSettingsLiveSmoke(_ store: BoardStore) async throws -> [String: Any] {
        guard AppArguments.value("--developer-database")?.hasPrefix("/tmp/kaban-fe20-") == true,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private FE-20 database and WindowGroup required") }
        let mode = AppArguments.value("--qa-mac-mode") ?? "settings"
        store.screen = mode == "flags" ? .board : .quota
        let editor = store.macSettings; editor.begin()
        guard let initial = editor.settings else { throw failure("Authoritative settings missing") }
        var checks: [String: Any] = ["mode": mode, "source": "private stdio daemon; quota/flags are producer-boundary fixtures, no token or Cursor requests",
                                    "authoritativeSettings": true, "quotaProducerAccepted": false]
        if mode == "flow" {
            guard !initial.quotaOptions.enabled, !initial.quotaOptions.consent else { throw failure("Quota default enabled") }
            editor.editCeiling("3")
            func primary(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.keyEquivalent == "\r", item.keyEquivalentModifierMask == .command { return item }
                    if let found = primary(item.submenu) { return found }
                }; return nil
            }
            guard let item = primary(NSApp.mainMenu), let menu = item.menu else { throw failure("Native settings command missing") }
            menu.update(); guard item.isEnabled else { throw failure("Native ceiling route disabled") }
            menu.performActionForItem(at: menu.index(of: item))
            try await waitUntil("ceiling event and reconciliation") { editor.receipt?.phase == .applied && store.canSend }
            editor.observeOutcome()
            guard editor.settings?.maxConcurrentRuns == 3 else { throw failure("Ceiling not confirmed") }
            if !store.macPaused { await store.toggleMacPause() }
            try await waitUntil("Mac pause event") { store.macPaused && store.canSend }
            if let id = store.projection?.projectOrder.first, !store.projectPaused(id) { await store.toggleProjectPause(id) }
            try await waitUntil("project pause event") { store.projection?.projectOrder.first.map { store.projectPaused($0) } == true && store.canSend }
            var options = initial.quotaOptions; options.enabled = true; editor.editOptions(options)
            guard !editor.canSubmit(.quota) else { throw failure("No consent allowed quota") }
            options.consent = true; options.thresholdCm = 17; options.thresholdOm = 23; editor.editOptions(options); editor.editInterval("900")
            guard await editor.submit(.quota) else { throw failure("Consented settings refused") }
            try await waitUntil("quota settings event and reconciliation") { editor.receipt?.phase == .applied && store.canSend }
            editor.observeOutcome()
            guard editor.settings?.quotaOptions.enabled == true, editor.settings?.quotaConsentedAt != nil,
                  editor.settings?.quotaOptions.pollInterval == 900 else { throw failure("Quota settings not durable") }
            checks["consentAndSettingsEvents"] = true
            checks["nativeCmdReturnCeilingRoute"] = true
        } else if mode == "restart" {
            guard initial.maxConcurrentRuns == 3, initial.quotaOptions.pollInterval == 900, initial.quotaOptions.thresholdCm == 17,
                  initial.quotaConsentedAt != nil, editor.section == .quota, store.macPaused,
                  store.projection?.projectOrder.first.map { store.projectPaused($0) } == true else { throw failure("Settings/pause restart failed") }
            checks["durableSettingsAndPauses"] = true
            checks["draftKeyboardRouteRestored"] = true
        } else if mode == "revoke" {
            var options = initial.quotaOptions; options.enabled = false; options.consent = false; editor.editOptions(options)
            guard await editor.submit(.quota) else { throw failure("Revoke refused") }
            try await waitUntil("consent revocation event") { editor.receipt?.phase == .applied && store.canSend }
            editor.observeOutcome()
            guard editor.settings?.quotaOptions.enabled == false, editor.settings?.quotaConsentedAt == nil else { throw failure("Revocation not confirmed") }
            checks["revocationConfirmed"] = true
        } else if mode == "revoked-restart" {
            guard !initial.quotaOptions.enabled, !initial.quotaOptions.consent, initial.quotaConsentedAt == nil else { throw failure("Revocation not persisted") }
        } else if mode == "flags" {
            let flags = store.projection?.ephemeral.schedulerFlags ?? []
            guard flags.contains(.runnerUnavailable(.runnerAuth)), flags.contains(.poolUsageExhausted(.om, resetsAt: nil)),
                  flags.contains(where: { if case .rateLimited = $0 { return true }; return false }), store.models.flags.count == 2 else { throw failure("Simultaneous flags missing") }
            let before = flags
            _ = await store.models.send(.resumeAfterRateLimit)
            try await waitUntil("rate-limit event") { store.models.receipt?.phase == .applied && store.canSend }
            guard store.projection?.ephemeral.schedulerFlags.contains(.runnerUnavailable(.runnerAuth)) == true,
                  store.projection?.ephemeral.schedulerFlags.contains(.poolUsageExhausted(.om, resetsAt: nil)) == true,
                  store.projection?.ephemeral.schedulerFlags.contains(where: { if case .rateLimited = $0 { return true }; return false }) == false else { throw failure("Rate resume erased unrelated flags") }
            checks["initialFlags"] = before.count; checks["rateLimitClearedByEventOnly"] = true
        }
        if mode == "unknown" || mode == "stale" || mode == "fresh" {
            let view = QuotaPresentation(pool: .cm, quota: store.projection?.ephemeral.quota, options: initial.quotaOptions, flags: [], now: Date())
            if mode == "fresh" { guard view.percent == 46 && view.cycleFraction != nil else { throw failure("Fresh quota missing") } }
            else { guard view.percent == nil && view.thresholdUsed == nil else { throw failure("Unknown/stale fabricated percent") } }
            checks["unknownRemainsUnknown"] = mode != "fresh"
        }
        if mode == "offline" {
            editor.editCeiling("11")
            await runtime?.closeDeveloperSession()
            guard !editor.canSubmit(.ceiling), editor.ceiling == "11" else { throw failure("Offline lost draft or enabled save") }
            checks["offlineDraftPreserved"] = true
        }
        if AppArguments.value("--qa-mac-scroll") == "bottom" {
            try await captureWindow()
            try await Task.sleep(for: .milliseconds(700))
            func scroll(_ view: NSView) -> NSScrollView? {
                if let found = view as? NSScrollView, found.documentView?.frame.height ?? 0 > found.contentView.bounds.height { return found }
                for child in view.subviews { if let found = scroll(child) { return found } }; return nil
            }
            if let view = window.contentView.flatMap(scroll), let document = view.documentView {
                view.contentView.scroll(to: .init(x: 0, y: document.isFlipped ? max(0, document.frame.height - view.contentView.bounds.height) : 0)); view.reflectScrolledClipView(view.contentView)
                checks["bottomViewport"] = true
            }
        }
        try await captureWindow()
        return checks
    }
}
#endif
