#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func modelLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = AppArguments.value("--model-live-repository"), path.hasPrefix("/tmp/kaban-fe14-"),
              AppArguments.value("--developer-database")?.hasPrefix("/tmp/kaban-fe14-") == true,
              let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Private model fixture or WindowGroup missing") }
        if AppArguments.value("--qa-size") == "minimum" { window.setContentSize(.init(width: 1040, height: 640)) }
        if !store.macPaused { _ = await store.session.send(.pauseAll); try await waitUntil("paused Mac for model QA") { store.macPaused && store.canSend } }
        if store.projection?.projects.values.contains(where: { $0.path == path }) != true {
            _ = await store.session.send(.addProject(path: path, createTemplate: false, identity: .init(name: "Model QA", email: "model@example.test")))
            try await waitUntil("model QA project") { store.projection?.projects.values.contains { $0.path == path } == true }
        }
        guard let project = store.projection?.projects.values.first(where: { $0.path == path }) else { throw failure("Model project missing") }
        let mode = AppArguments.value("--qa-model-mode") ?? "settings"
        store.screen = .quota
        if mode == "bootstrap" {
            guard store.models.rules != nil, store.models.catalogKnown else { throw failure("Model configuration unknown from real daemon") }
            if AppArguments.value("--export-live-window") != nil { try await captureWindow() }
            return ["real WindowGroup and private daemon", "confirmed empty catalog and saved pool rules", "Mac paused before configuring test CLI"]
        }
        let editor = store.pipelineEditor(for: project.id)
        await editor.loadIfNeeded()
        let exact = editor.content
        if mode == "refresh-error" {
            editor.edit(exact + "# Keep model draft\n", debounce: false)
            let draft = editor.content, rows = store.models.catalog, rules = store.models.rules
            _ = await store.models.send(.refreshModelCatalog)
            guard case .rejected(let error) = store.models.receipt?.phase, error.code == "model_catalog_refresh_failed",
                  store.models.catalog == rows, store.models.rules == rules, editor.content == draft else { throw failure("Failed refresh lost catalog, rules or draft") }
        } else {
            _ = await store.models.send(.refreshModelCatalog)
            try await waitUntil("correlated catalog refresh and reconciliation") { store.models.receipt?.phase == .applied && store.canSend }
            guard store.models.catalog.contains(where: { $0.id.rawValue == "gpt-qa" }),
                  !store.models.catalog.contains(where: { $0.id.rawValue.lowercased() == "auto" }) else { throw failure("Real catalog missing or Auto visible") }
        }
        if mode == "flow" {
            guard await store.models.send(.setModelPoolRule(pattern: "gpt-*", pool: .cm)) else { throw failure("Pool rule send refused") }
            try await waitUntil("correlated pool rule and reconciliation") { store.models.receipt?.phase == .applied && store.canSend }
            guard store.models.rules?.contains(where: { $0.pattern == "gpt-*" && $0.source == .user && $0.pool == .cm }) == true,
                  store.models.catalog.first(where: { $0.id.rawValue == "gpt-qa" })?.needsReview == false else { throw failure("Pool rule not authoritative") }
            guard await store.models.send(.removeModelPoolRule(pattern: "gpt-*")) else { throw failure("Pool rule removal send refused") }
            try await waitUntil("correlated rule removal and reconciliation") { store.models.receipt?.phase == .applied && store.canSend }
            guard store.models.rules?.contains(where: { $0.pattern == "gpt-*" && $0.source == .user }) == false else { throw failure("Rule removal not confirmed") }
            _ = await store.session.send(.createTask(projectId: project.id, title: "Модель задачи · проверка override", body: "## Критерии приёмки\n- [ ] Проверить модель\n"))
            try await waitUntil("created model task") { store.projection?.tasks.values.contains { $0.projectId == project.id } == true }
            guard let card = store.projection?.tasks.values.first(where: { $0.projectId == project.id }) else { throw failure("Task missing") }
            await store.select(card.id)
            try await waitUntil("model task detail") { store.detail?.modelStages?.isEmpty == false }
            guard let detail = store.detail, let override = TaskModelOverrideStore(detail: detail, session: store.session) else { throw failure("Override context missing") }
            override.model = "gpt-qa"
            _ = await override.submit()
            try await waitUntil("correlated task override") { override.receipt?.phase == .applied && store.detail?.modelStages?.first?.overrideModel?.rawValue == "gpt-qa" }
            guard editor.content == exact else { throw failure("Task override changed project draft") }
            guard let fresh = store.detail else { throw failure("Override detail missing") }
            guard let removal = TaskModelOverrideStore(detail: fresh, session: store.session) else { throw failure("Override removal context missing") }
            _ = await removal.submit(removing: true)
            try await waitUntil("correlated override removal") { removal.receipt?.phase == .applied && store.detail?.modelStages?.first?.overrideModel == nil }
            store.screen = .board
        } else if mode == "picker" || mode == "unknown" {
            if mode == "unknown" { editor.patch("stages[1].agent.model", value: "unknown-kept-long-model-id-from-old-pipeline", quoted: true) }
            store.openPipelineIssues(project.id)
            try await waitUntil("native pipeline picker") { store.activePipelineEditor === editor }
        } else if mode == "decision" || mode == "unconfirmed" {
            guard let card = store.projection?.tasks.values.first(where: { $0.projectId == project.id }) else { throw failure("Model decision task missing") }
            store.screen = .board; await store.select(card.id)
            try await waitUntil("model decision detail") { store.detail?.runs.isEmpty == false }
            guard let detail = store.detail, let run = detail.runs.first else { throw failure("Decision run missing") }
            if mode == "decision" {
                guard detail.task.state == .waitingHuman(.modelSubstituted), run.actualModelName == "GPT QA",
                      store.models.flags.contains(where: { $0.modelId.rawValue == "explicit" && $0.fallbackModel == "composer-qa" }) else { throw failure("Substitution facts missing") }
            } else {
                guard run.actualModelName == nil, detail.feed.contains(where: { $0.kind == "model_unconfirmed" }) else { throw failure("Unknown actual was fabricated") }
            }
        } else if mode == "override" {
            guard let card = store.projection?.tasks.values.first(where: { $0.projectId == project.id }) else { throw failure("Override capture task missing") }
            store.screen = .board; await store.select(card.id)
            try await waitUntil("override capture detail") { store.detail?.modelStages?.isEmpty == false }
            guard let detail = store.detail else { throw failure("Override capture detail missing") }
            store.openModelOverride(detail)
            try await waitUntil("real override sheet") { window.attachedSheet != nil }
        }
        if mode == "picker" {
            try await waitUntil("actual model picker popover") {
                NSApp.windows.contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }
            }
            guard let popover = NSApp.windows.first(where: { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }),
                  let view = popover.contentView?.superview ?? popover.contentView,
                  let path = AppArguments.value("--export-live-window") else { throw failure("Picker popover missing") }
            popover.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Picker capture unavailable") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Picker PNG missing") }
            try png.write(to: URL(fileURLWithPath: path + ".popover.png"))
        }
        if AppArguments.value("--export-live-window") != nil { try await captureWindow() }
        if mode == "decision" {
            _ = await store.models.send(.clearModelFlag(modelId: "explicit"))
            try await waitUntil("correlated clear model flag") { store.models.receipt?.phase == .applied && !store.models.flags.contains { $0.modelId.rawValue == "explicit" } }
        }
        if mode == "override", let sheet = window.attachedSheet {
            guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
                  sheet.performKeyEquivalent(with: escape) else { throw failure("Escape cannot cancel override") }
            try await waitUntil("Escape dismisses override") { window.attachedSheet == nil && store.modelOverrideRoute == nil }
        }
        return ["native WindowGroup and real daemon model commands", "catalog refresh and saved model facts", "mode: " + mode, "pipeline draft preserved"]
    }
}
#endif
