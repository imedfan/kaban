import SwiftUI
import KabanProtocol
import KabanBoardCore

enum TaskSheetRoute: Identifiable {
    case create(ProjectID)
    case edit(TaskCard, String?)
    case move(TaskCard)
    case cancel(TaskCard)
    case priority(TaskCard)
    var id: String {
        switch self {
        case .create(let id): "create-\(id.rawValue)"
        case .edit(let card, _): "edit-\(card.id.rawValue)"
        case .move(let card): "move-\(card.id.rawValue)"
        case .cancel(let card): "cancel-\(card.id.rawValue)"
        case .priority(let card): "priority-\(card.id.rawValue)"
        }
    }
}

struct TaskActionSheet: View {
    @Bindable var store: BoardStore
    let route: TaskSheetRoute
    @Environment(\.dismiss) private var dismiss
    @State private var controlRoute: TaskControlRoute?
    @State private var draft: DemoTaskDraft
    @State private var exactBody = ""
    @State private var preview = false
    @State private var compareCurrent = false
    @State private var priorityText = ""
    @State private var baseCard: TaskCard?
    @State private var keepBranch = false
    @State private var targetID: StageID?
    @FocusState private var titleFocused: Bool
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }

    init(store: BoardStore, route: TaskSheetRoute) {
        self.store = store; self.route = route
        switch route {
        case .move(let card): _controlRoute = State(initialValue: .init(store: store, card: card, action: .move(nil)))
        case .cancel(let card): _controlRoute = State(initialValue: .init(store: store, card: card, action: .cancel))
        default: _controlRoute = State(initialValue: nil)
        }
        _preview = State(initialValue: BoardQA.argument("--qa-task-preview") == "yes")
        _compareCurrent = State(initialValue: BoardQA.argument("--qa-compare-current") == "yes")
        let key: TaskDraftKey?
        switch route { case .create(let id): key = .create(id); case .edit(let card, _): key = .edit(card.id); case .priority(let card): key = .priority(card.id); default: key = nil }
        let saved = key.flatMap { store.session.drafts?.record(for: $0) }
        if case .edit(let task, let body) = route {
            _draft = State(initialValue: saved?.draft ?? DemoTaskDraft(title: task.title))
            _exactBody = State(initialValue: saved?.exactBody ?? body ?? "")
            _baseCard = State(initialValue: saved?.baseCard ?? task)
        } else {
            _draft = State(initialValue: saved?.draft ?? DemoTaskDraft())
            _exactBody = State(initialValue: saved?.exactBody ?? saved.map { $0.draft.body } ?? "")
            _baseCard = State(initialValue: nil)
        }
        if case .priority(let card) = route {
            _priorityText = State(initialValue: saved?.priorityText ?? String(card.priority))
            _baseCard = State(initialValue: card)
        }
    }
    private var draftKey: TaskDraftKey? {
        switch route { case .create(let id): .create(id); case .edit(let task, _): .edit(task.id); case .priority(let card): .priority(card.id); default: nil }
    }
    private func saveDraft() {
        guard let key = draftKey, !pending else { return }
        do { try store.session.drafts?.save(.init(key: key, draft: draft, exactBody: bodyKnown || store.session.drafts?.record(for: key)?.exactBody != nil ? exactBody : nil, baseCard: baseCard, priorityText: priorityText)) }
        catch { store.editorError = "Не удалось сохранить черновик. \(error.localizedDescription)" }
    }
    private var card: TaskCard? {
        switch route { case .edit(let card, _), .move(let card), .cancel(let card), .priority(let card): card; case .create: nil }
    }
    private var stale: Bool {
        guard let card else { return false }
        if case .priority = route { return store.projection?.tasks[card.id] == nil }
        return store.projection?.tasks[card.id] != (baseCard ?? card)
    }
    private var pending: Bool {
        if case .create(let id) = route { return store.session.pending(in: .project(id)) != nil }
        return card.map { store.projection?.isSent($0.id) ?? false } ?? false
    }
    private var bodyKnown: Bool {
        if case .edit(_, let body) = route { return body != nil }
        return true
    }
    var body: some View {
        if let controlRoute { TaskControlSheet(store: store, route: controlRoute) }
        else { editorBody }
    }
    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routeFields
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: formHeight)
            draftNotices
            HStack {
                Spacer()
                Button("Закрыть") { saveDraft(); dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction)
                Button(pending ? "Ожидаем…" : actionLabel) { Task { await submit() } }
                    .buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(pending || stale || !canSubmit || !store.can(actionCommand))
            }
        }.padding(24).frame(width: 560).background(theme.window)
            .onAppear { titleFocused = true }
            .onChange(of: draft) { _, _ in saveDraft() }
            .onChange(of: exactBody) { _, _ in saveDraft() }
            .onChange(of: priorityText) { _, _ in saveDraft() }
    }
    @ViewBuilder private var routeFields: some View {
                    switch route {
                    case .create(let projectID):
                        Text("Новая задача").font(.title3.bold())
                        Picker("Проект", selection: Binding(get: { projectID }, set: { id in
                            saveDraft(); store.selectedProjectID = id; store.sheet = .create(id)
                        })) {
                            ForEach(store.projection?.projectOrder ?? [], id: \.self) { id in
                                Text(store.projection?.projects[id]?.name ?? id.rawValue).tag(id)
                            }
                        }.disabled(pending)
                        editor
                    case .edit:
                        Text("Изменить задачу").font(.title3.bold())
                        editor
                    case .move(let task):
                        Text("Перенести задачу").font(.title3.bold())
                        Text(task.title)
                        if let pipeline = store.projection?.pipelines[task.projectId] {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(pipeline.stages.sorted { $0.display.order < $1.display.order }, id: \.id) { stage in
                                        let decision = TaskActions.moveDecision(card: task, target: stage, pipeline: pipeline)
                                        HStack(alignment: .top) {
                                            Button {
                                                targetID = stage.id
                                            } label: {
                                                Label(stage.name, systemImage: targetID == stage.id ? "largecircle.fill.circle" : "circle")
                                            }.buttonStyle(.plain).disabled(!decision.isAllowed || pending || stale)
                                            Spacer()
                                            if case .forbidden(let reason) = decision {
                                                Text(reason.text).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }.frame(maxHeight: 240)
                            if let targetID, let stage = pipeline.stages.first(where: { $0.id == targetID }),
                               case .allowed(let confirmation) = TaskActions.moveDecision(card: task, target: stage, pipeline: pipeline), let confirmation {
                                Text(confirmation).font(.callout)
                            }
                        } else { Text("Пайплайн недоступен").foregroundStyle(.secondary) }
                        suspiciousWarning(task)
                    case .priority(let task):
                        Text("Приоритет задачи").font(.title3.bold())
                        Text(task.title).font(.callout).lineLimit(3)
                        TextField("Целое число", text: $priorityText).textFieldStyle(.roundedBorder).disabled(pending)
                        Text("Большее число повышает приоритет при следующем выборе задачи планировщиком. Сейчас: \(store.projection?.tasks[task.id]?.priority ?? task.priority).")
                            .font(.caption).foregroundStyle(.secondary)
                    case .cancel(let task):
                        Text("Отменить задачу?").font(.title3.bold())
                        Text(task.title)
                        Text("Текущий запуск будет остановлен. Задача получит статус «Отменено».").font(.callout)
                        Toggle("Сохранить ветку", isOn: $keepBranch).disabled(task.branch == nil)
                        if task.branch == nil { Text("У задачи нет ветки для сохранения").font(.caption).foregroundStyle(.secondary) }
                        suspiciousWarning(task)
                    }
    }
    @ViewBuilder private var draftNotices: some View {
                    if stale {
                        Text("Задача изменилась. Сверьте текущий текст и состояние. Черновик сохранён.").font(.callout).foregroundStyle(theme.secondary)
                        if case .edit = route {
                            if let current = card.flatMap({ store.projection?.tasks[$0.id] }) {
                                Text("Сейчас: \(current.title) · \(CardPresentation(state: current.state).label)")
                                    .font(.caption).lineLimit(2).textSelection(.enabled).help(current.title)
                                DisclosureGroup("Текущее описание", isExpanded: $compareCurrent) {
                                    if let detail = store.detail, detail.task == current, let body = detail.body {
                                        ScrollView { TaskMarkdownView(source: body).frame(maxWidth: .infinity, alignment: .leading) }
                                            .frame(height: 96)
                                    } else { Text("Актуальное описание пока недоступно").font(.caption).foregroundStyle(.secondary) }
                                }
                                Button("Использовать мой черновик с текущей карточкой") {
                                    baseCard = current; saveDraft()
                                }.buttonStyle(KabanButtonStyle()).disabled(!TaskActions.canEdit(current))
                            }
                            Button("Удалить сохранённый черновик") {
                                if let key = draftKey { try? store.session.drafts?.discard(key) }
                                dismiss()
                            }.buttonStyle(KabanButtonStyle())
                        }
                    }
                    if case .edit = route, let current = card.flatMap({ store.projection?.tasks[$0.id] }), !TaskActions.canEdit(current) {
                        Text("Сейчас задачу нельзя редактировать. Поставьте её на паузу; черновик сохранён.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let label = pendingText { Text(label + " Можно закрыть окно — отправка сохранена.").font(.callout).foregroundStyle(theme.secondary) }
                    else if !store.canSend { Text("Черновик сохранён. Отправка будет доступна после синхронизации.").font(.callout).foregroundStyle(theme.secondary) }
                    if let error = store.editorError { Text(error).font(.callout).foregroundStyle(.orange) }
    }
    private var formHeight: CGFloat {
        switch route { case .create: 420; case .edit: stale ? (compareCurrent ? 210 : 270) : 420; case .move: 310; case .cancel: 180; case .priority: 140 }
    }
    private var pendingText: String? {
        switch route { case .create(let id): store.pendingLabel(.project(id)); default: card.flatMap { store.pendingLabel(.task($0.id)) } }
    }
    private var actionCommand: CommandName {
        switch route { case .create: .createTask; case .edit: .editTask; case .move: .moveTask; case .cancel: .cancelTask; case .priority: .setPriority }
    }
    private var editorHeight: CGFloat { stale ? (compareCurrent ? 80 : 140) : 220 }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Заголовок", text: $draft.title).accessibilityIdentifier("task.title").textFieldStyle(.roundedBorder).focused($titleFocused)
            HStack {
                Text("Описание и критерии приёмки").font(.headline)
                Spacer()
                Picker("Отображение", selection: $preview) {
                    Text("Markdown").tag(false)
                    Text("Просмотр").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 188)
            }
            if preview {
                ScrollView {
                    if exactBody.isEmpty { Text("Описание пока пусто").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    else { TaskMarkdownView(source: exactBody).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(12).frame(height: editorHeight).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            } else { markdownEditor($exactBody, height: editorHeight).disabled(!bodyKnown) }
            if !bodyKnown { Text("Описание недоступно. Можно изменить только заголовок; сохранённый текст не будет отправлен.").font(.caption).foregroundStyle(.secondary) }
            else if case .create = route {
                HStack {
                    Button("Добавить раздел критериев") { exactBody += TaskMarkdown.acceptanceCriteriaSeparator }
                        .buttonStyle(KabanButtonStyle())
                    Spacer()
                    Text("Критерии проверит служба после создания.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(pending)
    }
    private func markdownEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).accessibilityIdentifier("task.body").font(.system(size: 12)).scrollContentBackground(.hidden)
            .padding(8).frame(height: height).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.strongLine, lineWidth: 0.5))
    }
    private func suspiciousWarning(_ task: TaskCard) -> some View {
        Group {
            if !task.suspiciousFiles.isEmpty { Text("Текущий набор подозрительных файлов будет принят.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var actionLabel: String {
        switch route { case .create: "Создать"; case .edit: "Сохранить"; case .move: "Перенести"; case .cancel: "Отменить задачу"; case .priority: "Сохранить" }
    }
    private var canSubmit: Bool {
        switch route {
        case .create(let id): draft.canSubmit && store.projection?.projects[id] != nil
        case .edit(let task, _): draft.canSubmit && TaskActions.canEdit(task)
        case .move(let task):
            if let pipeline = store.projection?.pipelines[task.projectId], let target = pipeline.stages.first(where: { $0.id == targetID }) {
                TaskActions.moveDecision(card: task, target: target, pipeline: pipeline).isAllowed
            } else { false }
        case .cancel(let task): TaskActions.canCancel(task)
        case .priority(let task): Int(priorityText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil && TaskActions.canSetPriority(store.projection?.tasks[task.id] ?? task)
        }
    }
    private func submit() async {
        store.editorError = nil
        saveDraft()
        switch route {
        case .create(let projectID): _ = await store.create(draft, body: exactBody, in: projectID)
        case .edit(let task, _):
            guard let command = store.session.drafts?.editCommand(for: .edit(task.id), current: store.projection?.tasks[task.id], bodyIsKnown: bodyKnown) else { return }
            if await store.send(command, taskID: task.id, editor: true) { dismiss() }
        case .priority(let task):
            guard let priority = Int(priorityText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            if await store.send(.setPriority(taskId: task.id, priority: priority), taskID: task.id, editor: true) { dismiss() }
        case .move(let task):
            guard let targetID else { return }
            if await store.send(.moveTask(taskId: task.id, stage: targetID), taskID: task.id, editor: true) { dismiss() }
        case .cancel(let task):
            if await store.send(.cancelTask(taskId: task.id, keepBranch: keepBranch), taskID: task.id, editor: true) { dismiss() }
        }
    }
}
