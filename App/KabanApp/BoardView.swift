import SwiftUI
import KabanProtocol
import KabanBoardCore

struct BoardView: View {
    @Bindable var store: BoardStore
    @State private var sheet: TaskSheetRoute?
    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedProjectID) {
                Section("Проекты") {
                    ForEach(store.projection?.projectOrder ?? [], id: \.self) { id in
                        if let project = store.projection?.projects[id] {
                            HStack {
                                Image(systemName: "folder")
                                Text(project.name)
                                Spacer()
                                if project.openIncidentCount > 0 { Text("\(project.openIncidentCount)").foregroundStyle(.red) }
                                if store.visibleIDs.contains(id) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                            }
                            .tag(id)
                            .contextMenu {
                                if store.visibleIDs.contains(id) { Button("Скрыть с доски") { store.hide(id) } }
                                else { Button("Показать на доске") { store.show(id) } }
                            }
                        }
                    }
                }
                Section {
                    Label("Ждут человека · \(store.projection?.tasks.values.filter { $0.state.status == .waitingHuman }.count ?? 0)", systemImage: "person.crop.circle.badge.exclamationmark")
                    Label("Инциденты · \(store.projection?.openIncidentCount ?? 0)", systemImage: "exclamationmark.octagon")
                }
            }
            .navigationTitle("Kaban")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            HStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.projection == nil {
                            ProgressView("Загрузка доски…")
                        } else if store.projection?.projects.isEmpty == true {
                            ContentUnavailableView("Проектов пока нет", systemImage: "folder", description: Text("Демонстрационный клиент не содержит проектов."))
                        } else if store.visibleIDs.isEmpty {
                            ContentUnavailableView("Доска пуста", systemImage: "rectangle.split.3x1", description: Text("Выберите «Показать на доске» в меню проекта."))
                        }
                        ForEach(store.projection?.lanes(orderedBy: store.visibleIDs) ?? [], id: \.project.id) { lane in
                            laneView(lane)
                        }
                    }.padding(16)
                }
                if store.selectedID != nil {
                    Divider()
                    TaskDetailView(store: store, openSheet: { sheet = $0 }).frame(width: 340)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .navigationTitle("Доска")
            .toolbar {
                ToolbarItem { Label("Демонстрационные данные", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary) }
                ToolbarItem {
                    Button("Новая задача", systemImage: "plus") {
                        if let id = store.selectedProjectID { store.prepareCreation(); sheet = .create(id) }
                    }.keyboardShortcut("n").disabled(store.selectedProjectID == nil || store.creation.commandID != nil)
                }
            }
        }
        .sheet(item: $sheet) { route in TaskActionSheet(store: store, route: route) }
        .onChange(of: store.createdTaskID) { _, id in if id != nil { sheet = nil } }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Закрыть") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func laneView(_ lane: BoardLane) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lane.project.name).font(.system(size: 17, weight: .semibold))
                Text(lane.project.baseBranch).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Новая задача", systemImage: "plus") { store.selectedProjectID = lane.project.id; store.prepareCreation(); sheet = .create(lane.project.id) }
                    .disabled(store.creation.commandID != nil)
                Button { store.hide(lane.project.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Убрать с доски")
            }
            if lane.columns.isEmpty {
                Text("В проекте нет доступных стадий").foregroundStyle(.secondary)
            } else if lane.columns.allSatisfy({ $0.taskIds.isEmpty }) {
                Text("Задач пока нет. Создайте первую задачу в Backlog.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(lane.columns, id: \.stage.id) { column in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(column.stage.name).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if let load = store.projection?.load(projectId: lane.project.id, stageId: column.stage.id), let limit = load.wipLimit {
                                Text("\(load.wipUsed)/\(limit)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }.padding(4)
                        ForEach(column.taskIds, id: \.self) { id in
                            if let card = store.projection?.tasks[id] {
                                Button { Task { await store.select(id) } } label: {
                                    TaskCardView(card: card, selected: store.selectedID == id, sent: store.projection?.isSent(id) ?? false)
                                }.buttonStyle(.plain)
                            }
                        }
                        Spacer(minLength: 16)
                    }
                    .padding(8).frame(width: 220, alignment: .topLeading).frame(minHeight: 210)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(16).background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: DesignSystem.panelRadius))
    }
}

struct TaskCardView: View {
    let card: TaskCard
    let selected: Bool
    let sent: Bool
    var presentation: CardPresentation { CardPresentation(state: card.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(presentation.label, systemImage: presentation.symbol)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(DesignSystem.color(presentation.tone))
                Spacer(minLength: 0)
                Text("#\(card.id.rawValue)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(card.title).font(.system(size: 12, weight: .semibold)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(card.suspiciousFiles.prefix(2)), id: \.path) { file in
                Text("\(file.path) · \(file.rule == .pattern ? file.pattern ?? "по шаблону" : "превышен лимит размера")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if card.suspiciousFiles.count > 2 { Text("+\(card.suspiciousFiles.count - 2)").font(.caption2) }
            HStack {
                if let model = card.model { Text(model.rawValue).lineLimit(1) }
                Spacer()
                if sent { Text("Отправлено…") }
                else if card.attempt > 0, let limit = card.maxAttempts { Text("\(card.attempt)/\(limit)") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignSystem.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.cardRadius).stroke(selected ? Color.accentColor : .primary.opacity(0.07), lineWidth: selected ? 2 : 0.5))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .accessibilityElement(children: .combine)
    }
}

struct TaskDetailView: View {
    @Bindable var store: BoardStore
    let openSheet: (TaskSheetRoute) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Задача").font(.headline)
                    Spacer()
                    Button { Task { await store.select(nil) } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть детали")
                }
                if let detail = store.detail {
                    Text(detail.task.title).font(.system(size: 17, weight: .semibold))
                    let presentation = CardPresentation(state: detail.task.state)
                    Label(presentation.label, systemImage: presentation.symbol).foregroundStyle(DesignSystem.color(presentation.tone))
                    if let branch = detail.task.branch { Text(branch).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                    if detail.task.state == .running {
                        Button("Пауза", systemImage: "pause") { Task { await store.send(.pauseTask(taskId: detail.task.id), taskID: detail.task.id) } }
                            .disabled(store.projection?.isSent(detail.task.id) ?? false)
                    } else if detail.task.state == .paused {
                        Button("Продолжить", systemImage: "play") { Task { await store.send(.resumeTask(taskId: detail.task.id), taskID: detail.task.id) } }
                            .disabled(store.projection?.isSent(detail.task.id) ?? false)
                    }
                    HStack {
                        if TaskActions.canEdit(detail.task) {
                            Button("Изменить…") { store.editorError = nil; openSheet(.edit(detail.task, detail.body)) }
                        }
                        if TaskActions.canCancel(detail.task) {
                            Button("Перенести…") { openSheet(.move(detail.task)) }
                            Button("Отменить…") { openSheet(.cancel(detail.task)) }
                        }
                    }.disabled(store.projection?.isSent(detail.task.id) ?? false)
                    if let body = detail.body {
                        Divider()
                        Text("Описание и критерии приёмки").font(.headline)
                        Text(body.isEmpty ? "Описание пока пустое" : body).textSelection(.enabled)
                    }
                    if !detail.suspiciousFiles.isEmpty {
                        Divider()
                        Text("Подозрительные файлы").font(.headline)
                        ForEach(detail.suspiciousFiles, id: \.path) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text(file.rule == .pattern ? "по шаблону \(file.pattern ?? "—")" : "превышен лимит размера").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    Text("Лента").font(.headline)
                    if detail.feed.isEmpty { Text("Событий пока нет").foregroundStyle(.secondary) }
                    ForEach(detail.feed, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                            Text(item.at, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else { ProgressView("Загрузка…") }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(.background)
    }
}

enum TaskSheetRoute: Identifiable {
    case create(ProjectID)
    case edit(TaskCard, String?)
    case move(TaskCard)
    case cancel(TaskCard)
    var id: String {
        switch self {
        case .create(let id): "create-\(id.rawValue)"
        case .edit(let card, _): "edit-\(card.id.rawValue)"
        case .move(let card): "move-\(card.id.rawValue)"
        case .cancel(let card): "cancel-\(card.id.rawValue)"
        }
    }
}

struct TaskActionSheet: View {
    @Bindable var store: BoardStore
    let route: TaskSheetRoute
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DemoTaskDraft
    @State private var exactBody = ""
    @State private var keepBranch = false
    @State private var targetID: StageID?

    init(store: BoardStore, route: TaskSheetRoute) {
        self.store = store; self.route = route
        if case .edit(let task, let body) = route {
            _draft = State(initialValue: DemoTaskDraft(title: task.title))
            _exactBody = State(initialValue: body ?? "")
        }
        else { _draft = State(initialValue: DemoTaskDraft()) }
    }
    private var card: TaskCard? {
        switch route { case .edit(let card, _), .move(let card), .cancel(let card): card; case .create: nil }
    }
    private var stale: Bool {
        guard let card else { return false }
        return store.projection?.tasks[card.id] != card
    }
    private var pending: Bool {
        if case .create = route { return store.creation.commandID != nil }
        return card.map { store.projection?.isSent($0.id) ?? false } ?? false
    }
    private var bodyKnown: Bool {
        if case .edit(_, let body) = route { return body != nil }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch route {
            case .create(let projectID):
                Text("Новая задача · \(store.projection?.projects[projectID]?.name ?? "Проект")").font(.title3.bold())
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
            case .cancel(let task):
                Text("Отменить задачу?").font(.title3.bold())
                Text(task.title)
                Text("Текущий запуск будет остановлен. Задача получит статус «Отменено».").font(.callout)
                Toggle("Сохранить ветку", isOn: $keepBranch).disabled(task.branch == nil)
                if task.branch == nil { Text("У задачи нет ветки для сохранения").font(.caption).foregroundStyle(.secondary) }
                suspiciousWarning(task)
            }
            if stale { Text("Состояние задачи изменилось. Откройте действие снова.").font(.callout).foregroundStyle(.secondary) }
            if let error = store.editorError { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(pending)
                Button(pending ? "Отправлено…" : actionLabel) { Task { await submit() } }
                    .keyboardShortcut(.defaultAction).disabled(pending || stale || !canSubmit)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(pending)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Заголовок", text: $draft.title).textFieldStyle(.roundedBorder)
            if case .edit = route {
                Text("Описание и критерии приёмки · Markdown").font(.headline)
                TextEditor(text: $exactBody).frame(height: 220).border(.separator).disabled(!bodyKnown)
            } else {
                Text("Описание · Markdown").font(.headline)
                TextEditor(text: $draft.description).frame(height: 100).border(.separator)
                Text("Критерии приёмки").font(.headline)
                TextEditor(text: $draft.acceptanceCriteria).frame(height: 100).border(.separator)
            }
            if !bodyKnown { Text("Описание недоступно. Можно изменить только заголовок.").font(.caption).foregroundStyle(.secondary) }
            else if case .create = route, !draft.hasAcceptanceCriteria { Text("Без критериев приёмки задача останется в Backlog.").font(.caption).foregroundStyle(.secondary) }
        }.disabled(pending || stale)
    }
    private func suspiciousWarning(_ task: TaskCard) -> some View {
        Group {
            if !task.suspiciousFiles.isEmpty { Text("Текущий набор подозрительных файлов будет принят.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var actionLabel: String {
        switch route { case .create: "Создать"; case .edit: "Сохранить"; case .move: "Перенести"; case .cancel: "Отменить задачу" }
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
        }
    }
    private func submit() async {
        store.editorError = nil
        switch route {
        case .create(let projectID): await store.create(draft, in: projectID)
        case .edit(let task, _):
            if await store.send(.editTask(taskId: task.id, title: draft.title, body: bodyKnown ? exactBody : nil), taskID: task.id, editor: true) { dismiss() }
        case .move(let task):
            guard let targetID else { return }
            if await store.send(.moveTask(taskId: task.id, stage: targetID), taskID: task.id, editor: true) { dismiss() }
        case .cancel(let task):
            if await store.send(.cancelTask(taskId: task.id, keepBranch: keepBranch), taskID: task.id, editor: true) { dismiss() }
        }
    }
}
