import SwiftUI
import UniformTypeIdentifiers
import KabanProtocol
import KabanBoardCore

extension UTType {
    static let kabanTask = UTType(exportedAs: "app.kaban.task-drag", conformingTo: .data)
}
extension TaskDragItem: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kabanTask)
    }
}

struct TaskControlRoute: Identifiable {
    let request: TaskControlRequest
    let pipeline: PipelineSummary?
    let generation: UUID
    let id = UUID()
    @MainActor init(store: BoardStore, card: TaskCard, action: TaskControlRequest.Action) {
        request = .init(card: card, action: action)
        pipeline = store.projection?.pipelines[card.projectId]
        generation = store.session.sessionGeneration
    }
}

struct TaskControlSheet: View {
    @Bindable var store: BoardStore
    let route: TaskControlRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var stageFocused: Bool
    @State private var targetID: StageID?
    @State private var keepBranch = false
    @State private var grantEnabled = false
    @State private var grantText = "1"
    private var theme: KabanTheme { .init(dark: scheme == .dark) }
    private var card: TaskCard { route.request.card }
    private var current: TaskCard? { store.projection?.tasks[card.id] }
    private var stale: Bool {
        current != card || store.session.sessionGeneration != route.generation ||
        store.projection?.pipelines[card.projectId] != route.pipeline
    }
    private var pending: Bool { store.session.pending(in: .task(card.id)) != nil }
    private var grant: Int? { grantEnabled ? Int(grantText.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
    private var command: Command? {
        guard !stale, !pending, !grantEnabled || (grant != nil && grant! >= 0) else { return nil }
        return route.request.command(current: current, pipeline: route.pipeline, target: targetID,
                                     keepBranch: keepBranch, grantAttempts: grant)
    }
    private var name: CommandName { route.request.action.commandName }
    private var title: String {
        switch route.request.action {
        case .move: "Перенести задачу"
        case .cancel: "Отменить задачу?"
        case .retry: "Повторить стадию?"
        case .pause: "Приостановить задачу?"
        case .resume: "Продолжить задачу?"
        }
    }
    private var actionTitle: String {
        switch route.request.action {
        case .move: "Перенести"
        case .cancel: "Отменить задачу"
        case .retry: "Повторить стадию"
        case .pause: "Приостановить"
        case .resume: "Продолжить"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: route.request.action.symbol).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent).frame(width: 42, height: 42)
                    .background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text(card.id.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint)
                        .lineLimit(1).truncationMode(.middle).help(card.id.rawValue)
                }
                Spacer()
                KabanIconButton(symbol: "xmark", help: "Закрыть · Esc") { dismiss() }
            }
            Text(card.title).font(.system(size: 14, weight: .medium)).lineLimit(2).help(card.title)
            HStack(spacing: 7) {
                Text(route.pipeline?.stages.first { $0.id == card.stageId }?.name ?? card.stageId.rawValue)
                    .lineLimit(1).padding(.horizontal, 7).padding(.vertical, 4).background(theme.control, in: Capsule())
                Text(CardPresentation(card: card).label).lineLimit(2)
            }.font(.system(size: 11)).foregroundStyle(theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    actionForm
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: formHeight)
                .focusable(isMove).focused($stageFocused).focusEffectDisabled()
                .onMoveCommand { direction in
                    guard isMove, !stale, !pending, direction == .up || direction == .down, let pipeline = route.pipeline else { return }
                    let targets = pipeline.stages.sorted { $0.display.order < $1.display.order }
                        .filter { TaskActions.moveDecision(card: card, target: $0, pipeline: pipeline).isAllowed }
                    guard !targets.isEmpty else { return }
                    let step = direction == .down ? 1 : -1
                    if let index = targets.firstIndex(where: { $0.id == targetID }) {
                        targetID = targets[(index + step + targets.count) % targets.count].id
                    } else { targetID = (direction == .down ? targets.first : targets.last)?.id }
                }
            if card.state == .waitingHuman(.suspiciousFiles), !card.suspiciousFiles.isEmpty {
                Label("Действие примет текущий набор файлов с этим содержимым. Изменённый или новый файл будет проверен снова.", systemImage: "shield")
                    .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 10))
            }
            if !stale, case .move = route.request.action, card.state.status == .running || card.state.status == .gating {
                Label(DropRules.interruptConfirmation, systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(theme.secondary)
            }
            if stale {
                Label("Задача или пайплайн изменились. Закройте диалог и откройте действие снова.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(theme.secondary)
                if let current { Text("Сейчас: " + CardPresentation(card: current).label).font(.caption).foregroundStyle(theme.faint) }
            } else if let label = store.pendingLabel(.task(card.id)) {
                Label(label + " Можно закрыть диалог — отправка сохранена.", systemImage: "clock").font(.callout).foregroundStyle(theme.secondary)
            } else if !store.can(name) {
                Text(store.unavailableReason(name)).font(.callout).foregroundStyle(theme.secondary)
            }
            if let error = store.editorError { Text(error).font(.callout).foregroundStyle(.orange).lineLimit(3).help(error) }
            Divider()
            HStack {
                Text("Карточка обновится после подтверждения Kaban").font(.system(size: 10)).foregroundStyle(theme.faint)
                Spacer(minLength: 8)
                Button("Закрыть") { dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        guard let command else { return }
                        if await store.send(command, taskID: card.id, editor: true) { dismiss() }
                    }
                } label: {
                    Text(actionTitle).fixedSize(horizontal: true, vertical: false)
                }.buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(command == nil || !store.can(name))
                    .accessibilityIdentifier("task-control-submit")
            }
        }.padding(20).frame(width: 560).background(theme.window)
            .onAppear {
                if store.usesFixture && AppArguments.qaValue("--qa-state") == "control-cancel-keep" { keepBranch = true }
                if store.usesFixture, let text = AppArguments.qaValue("--qa-control-grant") { grantEnabled = true; grantText = text }
                if case .move(let suggested) = route.request.action { targetID = suggested; stageFocused = true }
            }
    }
    private var isMove: Bool { if case .move = route.request.action { true } else { false } }
    private var formHeight: CGFloat {
        if stale || pending || store.editorError != nil || card.state == .waitingHuman(.suspiciousFiles) { return 130 }
        if case .move = route.request.action { return 200 }
        if case .retry = route.request.action { return 190 }
        return 170
    }
    @ViewBuilder private var actionForm: some View {
        switch route.request.action {
        case .move:
            Text("Куда перенести").font(.callout.weight(.semibold))
            Text("↑ ↓ — выберите этап · Return — перенесите").font(.caption).foregroundStyle(theme.faint)
            if let pipeline = route.pipeline {
                ForEach(pipeline.stages.sorted { $0.display.order < $1.display.order }, id: \.id) { stage in
                    let decision = TaskActions.moveDecision(card: card, target: stage, pipeline: pipeline)
                    Button { targetID = stage.id } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: targetID == stage.id ? "largecircle.fill.circle" : "circle").foregroundStyle(targetID == stage.id ? theme.accent : theme.faint)
                            Text(stage.name).frame(width: 115, alignment: .leading).lineLimit(2)
                            Spacer(minLength: 0)
                            if case .forbidden(let reason) = decision { Text(reason.text).font(.caption).foregroundStyle(theme.faint).multilineTextAlignment(.trailing) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(targetID == stage.id ? theme.accent.opacity(0.08) : theme.control, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(!decision.isAllowed || stale || pending)
                }
            } else { Text("Пайплайн недоступен").foregroundStyle(theme.secondary) }
        case .cancel:
            Text("Kaban отменит задачу. Если у неё есть текущий запуск, он будет остановлен. Другие задачи продолжатся.").font(.callout)
            Toggle("Сохранить результат ветки", isOn: $keepBranch).disabled(stale || pending)
                .accessibilityIdentifier("task-cancel-keep-branch")
            Text("Если у задачи создана ветка, её последний коммит сохранится в репозитории проекта:")
                .font(.caption).foregroundStyle(theme.secondary)
            Text("refs/kaban/archive/" + card.id.rawValue).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).foregroundStyle(theme.secondary)
            Text("Клон будет удалён после обработки отмены. Сохранение не включает незакоммиченные изменения.")
                .font(.caption).foregroundStyle(theme.faint)
        case .retry:
            Text("Задача вернётся в очередь этой стадии. Новый запуск начнётся, когда планировщик разрешит его.").font(.callout)
            if let limit = card.maxAttempts { Text("Использовано попыток: \(card.attempt) из \(limit)").font(.caption).foregroundStyle(theme.secondary) }
            else { Text("Лимит попыток не передан службой").font(.caption).foregroundStyle(theme.faint) }
            Toggle("Добавить попытки", isOn: $grantEnabled).disabled(stale || pending)
            if grantEnabled {
                HStack {
                    Text("Количество").foregroundStyle(theme.secondary)
                    TextField("1", text: $grantText).textFieldStyle(.roundedBorder).frame(width: 90)
                        .accessibilityIdentifier("task-retry-attempts")
                    Spacer()
                }
                if grant == nil || grant! < 0 { Text("Укажите целое число от 0").font(.caption).foregroundStyle(.orange) }
            }
            Text("При исчерпанном лимите Kaban разрешит как минимум одну попытку. Счётчики возвратов не изменятся.")
                .font(.caption).foregroundStyle(theme.faint)
        case .pause:
            if card.state == .waitingHuman(.review) {
                Text("Kaban приостановит ожидание решения. После продолжения задача вернётся в Human Review, сохранив место на ревью.").font(.callout)
            } else if card.state.status == .running || card.state.status == .gating {
                Text("Kaban остановит текущий запуск этой задачи. После продолжения она вернётся в очередь этой стадии. Другие задачи продолжатся.").font(.callout)
            } else {
                Text("Kaban приостановит эту задачу. Она останется на своём этапе и вернётся в очередь после продолжения.").font(.callout)
            }
        case .resume:
            Text("Kaban продолжит задачу с сохранённого этапа. Пауза Мака или проекта может отложить новый запуск.")
                .font(.callout)
        }
    }
}

extension TaskControlRequest.Action {
    var commandName: CommandName {
        switch self { case .pause: .pauseTask; case .resume: .resumeTask; case .move: .moveTask; case .retry: .retryStage; case .cancel: .cancelTask }
    }
    var symbol: String {
        switch self { case .pause: "pause"; case .resume: "play"; case .move: "arrow.turn.up.left"; case .retry: "arrow.clockwise"; case .cancel: "xmark" }
    }
}
