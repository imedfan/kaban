import SwiftUI
import KabanProtocol
import KabanBoardCore

enum TaskMenuAction: Int, CaseIterable {
    case pauseOrResume = 701, move, retry, cancel
    var title: String {
        switch self {
        case .pauseOrResume: "Пауза / продолжить"
        case .move: "Перенести задачу…"
        case .retry: "Повторить стадию…"
        case .cancel: "Отменить задачу…"
        }
    }
    func request(for card: TaskCard) -> TaskControlRequest.Action {
        switch self {
        case .pauseOrResume: card.state == .paused ? .resume : .pause
        case .move: .move(nil)
        case .retry: .retry
        case .cancel: .cancel
        }
    }
}

extension BoardStore {
    var macPaused: Bool { projection?.ephemeral.schedulerFlags.contains(.macPaused) == true }
    func projectPaused(_ id: ProjectID) -> Bool { projection?.ephemeral.schedulerFlags.contains(.projectPaused(id)) == true }
    func toggleMacPause() async {
        let command: Command = macPaused ? .resumeAll : .pauseAll
        guard can(command.name), session.pending(in: .global) == nil else { return }
        _ = await session.send(command)
    }
    func toggleProjectPause(_ id: ProjectID) async {
        let command: Command = projectPaused(id) ? .resumeProject(projectId: id) : .pauseProject(projectId: id)
        guard projection?.projects[id] != nil, can(command.name), session.pending(in: .project(id)) == nil else { return }
        _ = await session.send(command)
    }
    var selectedCard: TaskCard? { selectedID.flatMap { projection?.tasks[$0] } }
    func canControl(_ card: TaskCard, action: TaskControlRequest.Action) -> Bool {
        guard projection?.tasks[card.id] == card, session.pending(in: .task(card.id)) == nil,
              can(action.commandName) else { return false }
        switch action {
        case .pause: return TaskActions.canPause(card)
        case .resume: return TaskActions.canResume(card)
        case .retry: return TaskActions.canRetry(card)
        case .cancel: return TaskActions.canCancel(card)
        case .move:
            guard let pipeline = projection?.pipelines[card.projectId] else { return false }
            return pipeline.stages.contains { TaskActions.moveDecision(card: card, target: $0, pipeline: pipeline).isAllowed }
        }
    }
    func beginControl(_ card: TaskCard, action: TaskControlRequest.Action) {
        guard gitPermissions.preview == nil, modelOverrideRoute == nil, sheet == nil, projectSheet == nil, controlSheet == nil, reviewRoute == nil, overlapRoute == nil, suspiciousReturnRoute == nil,
              logRunRoute == nil, materialTextRoute == nil, wipRestoreRoute == nil, canControl(card, action: action) else { return }
        editorError = nil
        controlSheet = .init(store: self, card: card, action: action)
    }
    func canPerform(_ menuAction: TaskMenuAction) -> Bool {
        guard gitPermissions.preview == nil, modelOverrideRoute == nil, sheet == nil, controlSheet == nil, projectSheet == nil, reviewRoute == nil, overlapRoute == nil, suspiciousReturnRoute == nil,
              logRunRoute == nil, materialTextRoute == nil, wipRestoreRoute == nil, let card = selectedCard else { return false }
        return canControl(card, action: menuAction.request(for: card))
    }
    func perform(_ menuAction: TaskMenuAction) {
        guard canPerform(menuAction), let card = selectedCard else { return }
        beginControl(card, action: menuAction.request(for: card))
    }
    func dragItem(_ card: TaskCard) -> TaskDragItem {
        .init(card: card, pipelineVersion: projection?.pipelines[card.projectId]?.versionHash, generation: session.sessionGeneration)
    }
    @discardableResult func dropTask(_ items: [TaskDragItem], project: ProjectID, stage: StageID) -> Bool {
        taskDropNotice = nil
        guard items.count == 1, let item = items.first, let pipeline = projection?.pipelines[project],
              let target = pipeline.stages.first(where: { $0.id == stage }) else { return false }
        let decision = item.decision(current: projection?.tasks[item.card.id], target: target, pipeline: pipeline, generation: session.sessionGeneration)
        guard decision.isAllowed else {
            if case .forbidden(let reason) = decision { taskDropNotice = reason.text }
            return false
        }
        guard canControl(item.card, action: .move(stage)), sheet == nil, projectSheet == nil, controlSheet == nil else { return false }
        beginControl(item.card, action: .move(stage))
        return controlSheet != nil
    }
}

struct TaskControlMenu: View {
    @Bindable var store: BoardStore
    let card: TaskCard
    var body: some View {
        if TaskActions.canPause(card) {
            Button("Приостановить…") { store.beginControl(card, action: .pause) }.disabled(!store.canControl(card, action: .pause))
        }
        if TaskActions.canResume(card) {
            Button("Продолжить…") { store.beginControl(card, action: .resume) }.disabled(!store.canControl(card, action: .resume))
        }
        if TaskActions.canRetry(card) {
            Button("Повторить стадию…") { store.beginControl(card, action: .retry) }.disabled(!store.canControl(card, action: .retry))
        }
        if TaskActions.canCancel(card) {
            Button("Перенести…") { store.beginControl(card, action: .move(nil)) }.disabled(!store.canControl(card, action: .move(nil)))
            Button("Отменить задачу…", role: .destructive) { store.beginControl(card, action: .cancel) }.disabled(!store.canControl(card, action: .cancel))
        }
    }
}

struct TaskDropTarget: ViewModifier {
    @Bindable var store: BoardStore
    let project: ProjectID
    let stage: StageID
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
            .dropDestination(for: TaskDragItem.self) { items, _ in
                store.dropTask(items, project: project, stage: stage)
            } isTargeted: { targeted = $0 }
    }
}

struct TaskDragSource: ViewModifier {
    @Bindable var store: BoardStore
    let card: TaskCard
    func body(content: Content) -> some View {
        if store.canControl(card, action: .move(nil)), store.projection?.pipelines[card.projectId]?.versionHash?.isEmpty == false {
            content.draggable(store.dragItem(card))
        } else { content }
    }
}
