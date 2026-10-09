#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func gitPermissionsLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard AppArguments.value("--developer-database")?.hasPrefix("/tmp/kaban-fe17-") == true,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }), store.macPaused else {
            throw failure("Private git fixture, paused Mac or WindowGroup missing")
        }
        window.setContentSize(AppArguments.value("--qa-size") == "minimum" ? .init(width: 1040, height: 640) : .init(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        let mode = AppArguments.value("--qa-git-mode") ?? "fresh"
        let name = ["flow", "reopen", "disconnected"].contains(mode) ? "fresh" : ["preview-project", "preview-stage", "policy"].contains(mode) ? "policy" : mode == "retry" ? "limit" : mode
        let id = TaskID(rawValue: "git-" + name)
        await store.select(id); store.detailTab = "Разрешения git"
        try await waitUntil("durable git detail") { store.detail?.task.id == id && store.session.detailReadState == .loaded && store.canSend }
        guard let detail = store.detail else { throw failure("Git detail missing") }
        var checks = ["real WindowGroup, production daemon over private stdio, durable denial produced by loopback /git/check"]
        if mode == "flow" {
            guard let denial = detail.gitDenials.first, store.gitPermissions.canAllow(denial) else { throw failure("Fresh denial unavailable") }
            await store.gitPermissions.allow(denial)
            try await waitUntil("correlated grant and board badge") {
                store.detail?.gitGrants.count == 1 && store.detail?.task.unusedGitGrants == 1
                    && store.projection?.tasks[id]?.unusedGitGrants == 1 && store.canSend
            }
            let count = store.commandJournal?.records.count
            await store.gitPermissions.allow(denial)
            guard store.commandJournal?.records.count == count, let grant = store.detail?.gitGrants.first else { throw failure("Duplicate grant") }
            await store.gitPermissions.revoke(grant)
            try await waitUntil("correlated revoke and board badge") {
                store.detail?.gitGrants.first?.revocation != nil && store.detail?.task.unusedGitGrants == 0
                    && store.projection?.tasks[id]?.unusedGitGrants == 0 && store.canSend
            }
            checks.append("allow and revoke use correlated events; .ok creates no local grant; repeat allow sends no second intent; authoritative badge 0 → 1 → 0")
        } else if mode == "reopen" {
            guard detail.gitGrants.count == 1, detail.gitGrants[0].revocation != nil, detail.task.unusedGitGrants == 0 else { throw failure("Reopen lost lifecycle") }
            checks.append("new app and daemon restore revoked lifecycle and zero unused badge from SQLite")
        } else if mode.hasPrefix("preview-") || mode == "policy" {
            guard let denial = detail.gitDenials.first else { throw failure("Policy denial missing") }
            store.gitPermissions.openPreview(denial)
            try await waitUntil("native policy sheet and resolved draft") {
                window.attachedSheet != nil && store.gitPermissions.preview?.editor.loading == false
                    && store.gitPermissions.preview?.editor.lastResolved != nil
            }
            guard let preview = store.gitPermissions.preview else { throw failure("Policy preview missing") }
            if mode != "preview-project" {
                guard let stage = denial.context?.stageId else { throw failure("Stage unknown") }
                await preview.choose(.stage(stage))
            }
            try await waitUntil("rule preview ready") { preview.canSave }
            guard preview.editor.submission == nil, preview.editor.source?.hasWorkingChanges == false else { throw failure("Preview wrote configuration") }
            guard !store.canPerform(.cancel), !store.canAnswerSelected, !store.canApproveSelected else { throw failure("Background task shortcut enabled behind git preview") }
            checks.append("native preview shows explicit scope, exact YAML and server-resolved policy before disk write")
            if mode == "policy" {
                let original = preview.editor.source?.baseVersionHash
                guard let sheet = window.attachedSheet,
                      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: sheet.windowNumber,
                                               context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                      NSApp.mainMenu?.performKeyEquivalent(with: key) == true else {
                    throw failure("Native Cmd-Return menu action unavailable")
                }
                try await waitUntil("committed policy version and source proof") {
                    preview.acceptedVersion != nil && preview.acceptedVersion != original && store.canSend
                        && store.session.detailReadState == .loaded
                        && store.detail?.gitDenials.first?.policyUpdates?.last?.pipelineVersion == preview.acceptedVersion
                }
                guard let update = store.detail?.gitDenials.first?.policyUpdates?.last,
                      update.pipelineVersion == preview.acceptedVersion, update.scope == .stage("dev") else { throw failure("Durable policy update missing") }
                checks.append("native Cmd-Return menu command saves one addDenialToPolicy intent; correlated accepted version differs from base and exact committed source matches; durable resolved stage policy retained")
            } else if CommandLine.arguments.contains("--qa-git-escape") {
                guard let sheet = window.attachedSheet,
                      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber,
                                               context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
                      sheet.performKeyEquivalent(with: key) else { throw failure("Native Escape missing") }
                try await waitUntil("preview closes") { window.attachedSheet == nil && store.gitPermissions.preview == nil }
                checks.append("native Escape closes preview without creating a command or changing YAML")
            }
        } else if mode == "disconnected" {
            store.stop()
            guard detail.gitDenials.allSatisfy({ !store.gitPermissions.canAllow($0) && !store.gitPermissions.canPreview($0) }),
                  detail.gitGrants.allSatisfy({ !store.gitPermissions.canRevoke($0) }) else { throw failure("Disconnected mutation available") }
            checks.append("durable history remains visible; disconnected actions disabled")
        } else if mode == "retry" {
            guard detail.task.state == .waitingHuman(.gitDenials) else { throw failure("Five-denial wait missing") }
            _ = await store.session.send(.retryStage(taskId: id, grantAttempts: nil))
            try await waitUntil("git-denials retry") { store.detail?.task.state.status == .queued && store.canSend }
            checks.append("five real denials wait for a human; retryStage queues the same stage while Mac remains paused")
        } else if let grant = detail.gitGrants.first {
            let expected: GitGrantPresentation.State
            switch mode { case "created": expected = .created; case "delivered": expected = .delivered; case "consumed": expected = .consumed; case "revoked": expected = .revoked; case "expired": expected = .expired; default: throw failure("Unexpected lifecycle mode") }
            guard GitGrantPresentation(grant, detail: detail).state == expected else { throw failure("Lifecycle state lost") }
            checks.append("durable \(expected.rawValue) remains distinct with backend timestamps after daemon recovery")
        } else if mode == "hard" {
            guard detail.gitDenials.first?.context?.restriction?.code == "git_hard_invariant",
                  detail.gitDenials.allSatisfy({ !store.gitPermissions.canAllow($0) && !store.gitPermissions.canPreview($0) }) else { throw failure("Hard lock bypass") }
            checks.append("hard-invariant denial offers no allow or policy buttons")
        } else if mode == "stale" {
            guard detail.gitDenials.first?.context?.restriction?.code == "stale_git_denial" else { throw failure("Stale denial restriction missing") }
            checks.append("cancelled task retains raw denial and explicit stale refusal")
        } else if mode == "unknown" {
            guard detail.gitDenials.first?.denial.rule == "unknown" else { throw failure("Unknown rule rewritten") }
            checks.append("unknown rule and argv displayed verbatim")
        } else if mode == "empty" {
            guard detail.gitDenials.isEmpty, detail.gitGrants.isEmpty, detail.task.unusedGitGrants == 0 else { throw failure("Empty history fabricated") }
            checks.append("empty task shows no invented denial or grant")
        }
        try await captureWindow()
        return checks
    }
}
#endif
