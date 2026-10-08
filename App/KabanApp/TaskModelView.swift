import SwiftUI
import KabanProtocol
import KabanBoardCore

extension TaskModelOverrideStore: Identifiable { nonisolated public var id: TaskID { taskID } }

struct TaskModelView: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    let theme: ReferenceTheme
    private var stage: TaskModelStage? { detail.modelStages?.first { $0.stageId == detail.task.stageId } }
    private var run: RunSummary? { detail.runs.filter { $0.stageId == detail.task.stageId }.max { $0.number < $1.number } }
    private var flags: [ModelFlag] {
        store.models.flags.filter { $0.modelId == stage?.resolvedModel || $0.modelId == run?.requestedModel }
    }
    var body: some View {
        if detail.modelStages?.isEmpty == false || run != nil {
            VStack(alignment: .leading, spacing: 10) {
                Label("Модель задачи", systemImage: "cpu").font(.system(size: 13, weight: .semibold))
                if let stage {
                    modelLine("Модель стадии в этой задаче", stage.stageModel.rawValue)
                    modelLine("Следующий запуск", stage.resolvedModel.rawValue + (stage.overrideModel == nil ? " · из стадии" : " · override"))
                }
                if let run {
                    modelLine("Запрошена · запуск №\(run.number)", run.requestedModel.rawValue)
                    modelLine("Фактическая модель", run.actualModelName ?? "Не подтверждена")
                    if run.endReason == .modelSubstituted { Text("Подмена остановила этот запуск до работы с инструментами.").font(.caption).foregroundStyle(.orange) }
                    if detail.feed.contains(where: { $0.kind == "model_unconfirmed" && $0.runId == run.id }) {
                        Text("Фактическое имя не подтверждено каталогом. Совпадение с запрошенной моделью неизвестно.").font(.caption).foregroundStyle(.orange)
                    }
                }
                ForEach(flags, id: \.modelId) { flag in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(flag.reason == .unavailable ? "Модель недоступна" : "Флаг модели: обнаружена подмена").font(.caption.bold()).foregroundStyle(.orange)
                        modelLine("Запрошена", flag.requested)
                        if flag.reason == .substituted { modelLine("Получена", flag.actual ?? "Не подтверждена") }
                        if let fallback = flag.fallbackModel { modelLine("Fallback из сообщения Cursor", fallback) }
                        Button("Снять флаг модели") { Task { await store.models.send(.clearModelFlag(modelId: flag.modelId)) } }
                            .disabled(!store.models.can(.clearModelFlag(modelId: flag.modelId)))
                    }.padding(8).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                HStack(spacing: 8) {
                    Button("Другая модель…") { store.openModelOverride(detail) }.disabled(!store.canOverrideModel(detail))
                        .accessibilityIdentifier("task-model-change")
                    if TaskActions.canRetry(detail.task) {
                        Button("Повторить…") { store.beginControl(detail.task, action: .retry) }.disabled(!store.canControl(detail.task, action: .retry))
                    }
                    if let pipeline = store.projection?.pipelines[detail.task.projectId], let backlog = pipeline.stages.first(where: { $0.kind == .queue }), backlog.id != detail.task.stageId {
                        Button("В Backlog…") { store.beginControl(detail.task, action: .move(backlog.id)) }
                            .disabled(!TaskActions.moveDecision(card: detail.task, target: backlog, pipeline: pipeline).isAllowed || !store.canControl(detail.task, action: .move(backlog.id)))
                    }
                }.buttonStyle(KabanButtonStyle(compact: true))
                if !flags.isEmpty { Text("Снятие флага разрешает новую проверку, но не гарантирует успешный запуск.").font(.caption).foregroundStyle(theme.secondary) }
            }.padding(12).background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        } else if detail.modelStages == nil {
            Text("Служба не передала модели frozen pipeline и task override.").font(.caption).foregroundStyle(theme.secondary)
        }
    }
    private func modelLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(theme.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TaskModelOverrideSheet: View {
    @Bindable var store: BoardStore
    @Bindable var editor: TaskModelOverrideStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Модель конкретной задачи").font(.title2.bold())
            Text(editor.card.title).font(.headline).lineLimit(3)
            Picker("Стадия", selection: Binding(get: { editor.stageID }, set: { editor.selectStage($0) })) {
                ForEach(editor.stages, id: \.stageId) { Text($0.name + " · " + $0.stageId.rawValue).tag($0.stageId) }
            }.disabled(editor.pending)
            if let stage = editor.stage {
                Text("Модель стадии: " + stage.stageModel.rawValue).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                if let override = stage.overrideModel { Text("Сохранённый override: " + override.rawValue).font(.caption).textSelection(.enabled) }
            }
            ModelPicker(store: store.models, selection: $editor.model, theme: theme).disabled(editor.pending)
            Text("Изменение действует только для этой задачи и выбранной стадии, со следующего запуска. Счётчик запусков после участия человека сбросится. Текущий запуск сохранит свою модель и параметры.")
                .font(.callout).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            if editor.stale {
                Text("Задача или соединение изменились. Сверьте данные перед отправкой; выбранная модель сохранена.").font(.caption).foregroundStyle(.orange)
                Button("Сверить задачу") { Task { await store.session.retryDetail(); if let detail = store.detail { editor.reconcile(detail) } } }
                    .disabled(!store.canSend || editor.pending)
            }
            if let error = editor.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if editor.pending { HStack { ProgressView().controlSize(.small); Text("Ожидаем подтверждение override…").font(.caption) } }
            HStack {
                Button("Снять override") { Task { await editor.submit(removing: true) } }.disabled(!editor.canSubmit(removing: true))
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") { Task { await editor.submit() } }.buttonStyle(KabanButtonStyle(primary: true)).disabled(!editor.canSubmit()).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 510).interactiveDismissDisabled(editor.pending)
            .onChange(of: editor.receipt?.phase) { _, phase in if phase == .applied { dismiss() } }
    }
}

extension BoardStore {
    func canOverrideModel(_ detail: TaskDetail) -> Bool {
        detail.modelStages?.isEmpty == false && session.detailReadState == .loaded && projection?.tasks[detail.task.id] == detail.task
            && ![.done, .cancelled].contains(detail.task.state.status) && session.pending(in: .task(detail.task.id)) == nil && can(.setModelOverride)
    }
    func openModelOverride(_ detail: TaskDetail) {
        guard canOverrideModel(detail), sheet == nil, controlSheet == nil, projectSheet == nil, reviewRoute == nil,
              logRunRoute == nil, wipRestoreRoute == nil, overlapRoute == nil, materialTextRoute == nil else { return }
        modelOverrideRoute = TaskModelOverrideStore(detail: detail, session: session)
    }
}
