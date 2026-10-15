#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

extension BoardQA {
    static func incidentLiveSmoke(_ store: BoardStore) async throws -> [String: Any] {
        let mode = AppArguments.value("--qa-incident-mode") ?? "refs"
        store.screen = .incidents; store.incidents.scheduleRefresh()
        try await waitUntil("durable incident list") { store.incidents.isCurrent }
        guard let projection = store.projection,
              projection.openIncidentCount == projection.projects.values.reduce(0, { $0 + $1.openIncidentCount }) else { throw failure("Backend aggregate differs from project counts") }
        var checks: [String: Any] = ["mode": mode, "countFromProjectSummaries": true, "allProjectsQuery": true]
        if mode == "empty" {
            guard store.incidents.records.isEmpty, projection.openIncidentCount == 0 else { throw failure("Nonempty empty fixture") }
            try await captureWindow(); checks["empty"] = true; return checks
        }
        guard let database = AppArguments.value("--developer-database") else { throw failure("Private database missing") }
        let root = URL(fileURLWithPath: database).deletingLastPathComponent()
        let metadata = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("seed.json")))
        let name = mode == "deleted-log" ? "deleted" : ["hidden", "model", "return", "reopen", "missing-log", "retention", "disconnected", "policy"].contains(mode) ? "refs" : mode
        guard let raw = metadata[name], let incident = store.incidents.records.first(where: { $0.id.rawValue == raw }) else { throw failure("Seed incident missing: " + name) }
        store.incidents.filter = ["deleted", "deleted-log", "reopen"].contains(mode) ? .all : .open
        store.incidents.selectedID = incident.id
        if mode == "hidden" {
            store.session.hide(incident.projectId)
            guard !store.visibleIDs.contains(incident.projectId), store.incidents.visible.contains(where: { $0.id == incident.id }) else { throw failure("Hidden incident lost") }
            checks["hiddenProjectVisible"] = true
        }
        await store.select(incident.taskId)
        if ["deleted", "deleted-log"].contains(mode) {
            guard store.projection?.projects[incident.projectId] == nil, store.projection?.tasks[incident.taskId] == nil,
                  incident.resolvedAt != nil, incident.resolution?.command == "cancelTask" else { throw failure("Deleted project history lost") }
            checks["deletedHistoryReadable"] = true
            if mode == "deleted-log" {
                guard let run = store.detail?.runs.first else { throw failure("Deleted run source missing") }
                store.logRunRoute = run
                try await waitUntil("deleted task log sheet diagnosis") { if case .unavailable = store.runLog.state { return true }; return false }
                checks["deletedTaskLogSheetReadable"] = true
            }
        } else {
            try await waitUntil("incident task detail") { store.session.detailReadState == .loaded && store.detail?.task.id == incident.taskId }
            try await waitUntil("incident list after detail selection") { store.incidents.isCurrent }
            guard let detail = store.detail else { throw failure("Detail missing") }
            if mode == "unknown" {
                guard !incident.kind.isKnown, incident.kind.rawValue == "future_protection_violation",
                      store.incidentDecisions.currentContext(incident.id) == nil else { throw failure("Future kind decoded incorrectly") }
                checks["simulatedFutureKindReadable"] = true
            } else if mode == "reopen" {
                guard incident.resolution?.command == "requestChanges", incident.resolution?.target == "dev",
                      detail.task.state != .waitingHuman(.incident) else { throw failure("Resolution history did not survive process restart") }
                checks["resolutionHistoryAfterRestart"] = true
            } else {
                guard detail.task.state == .waitingHuman(.incident), !incident.rolledBack.isEmpty,
                      store.incidentDecisions.currentContext(incident.id) != nil else { throw failure("Rollback/action facts missing: state=\(detail.task.state), rolled=\(incident.rolledBack.count), reader=\(store.incidents.isCurrent), frozen=\(String(describing: detail.incidentPipeline?.versionHash)), valid=\(String(describing: detail.incidentPipeline?.isValid)), cardEqual=\(store.projection?.tasks[incident.taskId] == detail.task), selected=\(String(describing: store.selectedID))") }
                checks["actualRollback"] = true
                checks["frozenTargets"] = store.incidentDecisions.currentContext(incident.id)?.targets.map { $0.id.rawValue }
            }
            if mode == "disconnected" {
                await runtime?.closeDeveloperSession()
                await store.incidents.refresh()
                guard store.incidents.records.contains(where: { $0.id == incident.id }), !store.canResolveIncident,
                      case .failed = store.incidents.readState else { throw failure("Disconnected history/actions invalid") }
                checks["disconnectedCacheReadable"] = true
            }
            if mode == "policy" {
                let before = store.projection?.openIncidentCount
                store.openIncidentPolicy(incident.projectId)
                try await waitUntil("project Git draft route") { store.activePipelineEditor?.selectedStageID == "__git" }
                guard store.projection?.openIncidentCount == before, store.projection?.tasks[incident.taskId]?.state == .waitingHuman(.incident) else { throw failure("Policy route resolved incident") }
                checks["policyRouteKeepsIncidentOpen"] = true
            }
            if mode == "model" {
                guard let editor = TaskModelOverrideStore(detail: detail, session: store.session), editor.canSubmit(removing: true) else { throw failure("Seed override cannot be removed") }
                let before = store.projection?.openIncidentCount
                store.modelOverrideRoute = editor
                let sent = await editor.submit(removing: true)
                guard sent else { throw failure("Model removal rejected") }
                try await waitUntil("model command event") { editor.receipt?.phase == .applied }
                try await waitUntil("model detail refresh") { store.detail?.modelStages?.first(where: { $0.stageId == "dev" })?.overrideModel == nil && store.session.detailReadState == .loaded }
                guard store.projection?.tasks[incident.taskId]?.state == .waitingHuman(.incident), store.projection?.openIncidentCount == before else { throw failure("Model change resumed incident") }
                store.modelOverrideRoute = nil; checks["modelChangeDoesNotResume"] = true
            }
            if mode == "return" {
                let before = store.projection?.openIncidentCount ?? 0
                store.incidentDecisions.edit(incident.id, comments: "Проверь защищённые refs  \r\n👋", target: "dev")
                guard store.canResolveIncident else { throw failure("Explicit return unavailable") }
                func primary(_ menu: NSMenu?) -> NSMenuItem? {
                    for item in menu?.items ?? [] {
                        if ["Ответить или одобрить результат", "Отправить ответ агенту", "Вернуть с замечанием по инциденту"].contains(item.title) { return item }
                        if let found = primary(item.submenu) { return found }
                    }
                    return nil
                }
                guard let item = primary(NSApp.mainMenu), let menu = item.menu else { throw failure("Native Cmd-Return menu missing") }
                menu.update(); guard item.isEnabled else { throw failure("Native menu decision disabled") }
                menu.performActionForItem(at: menu.index(of: item))
                try await waitUntil("incident decision correlated event") { store.incidentDecisions.receipt(incident.id)?.phase == .applied }
                store.incidents.scheduleRefresh()
                try await waitUntil("resolved incident durable history") { store.incidents.isCurrent && store.incidents.records.first(where: { $0.id == incident.id })?.resolvedAt != nil }
                guard let resolved = store.incidents.records.first(where: { $0.id == incident.id }), resolved.resolution?.command == "requestChanges",
                      resolved.resolution?.target == "dev", store.projection?.tasks[incident.taskId]?.state != .waitingHuman(.incident),
                      store.projection?.openIncidentCount == before - 1 else { throw failure("Resolution/card/count differ") }
                store.incidents.filter = .all
                checks["returnViaNativeMenu"] = true; checks["resolutionCardCountConfirmed"] = true
            }
            if mode == "missing-log" {
                guard let run = detail.runs.first else { throw failure("Incident run summary missing") }
                store.logRunRoute = run
                try await waitUntil("missing log diagnosis") { if case .unavailable = store.runLog.state { return true }; return false }
                checks["missingLogReadable"] = true
            }
        }
        try await captureWindow()
        checks["source"] = "bundled stdio private daemon; paid CLI and service registration unused"
        return checks
    }
}
#endif
