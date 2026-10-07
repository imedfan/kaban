import SwiftUI
import KabanProtocol
import KabanBoardCore

enum BoardScreen: Equatable { case board, project(ProjectID), quota }
enum BoardFilter: String, CaseIterable { case all = "Доска", waiting = "Ждут человека", incidents = "Инциденты" }

struct BoardView: View {
    @Bindable var store: BoardStore
    @Environment(\.colorScheme) private var scheme
    @State private var sidebarVisible = true
    @State private var collapsed: Set<ProjectID> = []
    @State private var byStage = false
    @FocusState private var searchFocused: Bool
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var lanes: [BoardLane] { store.projection?.lanes(orderedBy: store.visibleIDs) ?? [] }
    private var title: String {
        switch store.screen { case .board: store.filter.rawValue; case .project: "Настройки проекта"; case .quota: "Этот Мак" }
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if sidebarVisible { sidebar.frame(width: 232); theme.line.frame(width: 0.5) }
                VStack(spacing: 0) {
                    header(width: geometry.size.width - (sidebarVisible ? 233 : 0))
                    connectionBanner
                    switch store.screen {
                    case .board:
                        board(width: max(geometry.size.width - (sidebarVisible ? 233 : 0), 0))
                    case .project(let id):
                        ProjectSettingsView(store: store, projectID: id, theme: theme)
                    case .quota:
                        quotaPage
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ReferenceBackdrop(theme: theme))
        }
        .foregroundStyle(theme.text)
        .id(store.qaLayoutRevision)
        .sheet(item: $store.sheet) { TaskActionSheet(store: store, route: $0) }
        .sheet(item: $store.projectSheet) { ProjectLifecycleSheet(store: store, route: $0) }
        .onChange(of: store.projection?.projectOrder) { _, ids in
            if case .project(let id) = store.screen, ids?.contains(id) != true { store.screen = .board }
        }
        .onChange(of: store.createdTaskID) { _, id in
            if let id, case .create(let project) = store.sheet,
               store.projection?.tasks[id]?.projectId == project,
               store.session.drafts?.record(for: .create(project)) == nil { store.sheet = nil }
        }
        .onChange(of: store.session.visibleIDs, initial: true) { _, _ in store.updateVisibleProjects() }
        .onChange(of: store.projection == nil) { _, loading in
            if !loading {
                collapsed = Set(lanes.filter { $0.columns.allSatisfy { $0.taskIds.isEmpty } }.map(\.project.id))
            }
        }
        .onChange(of: store.searchRequest) { _, _ in searchFocused = true }
        .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.error != nil && store.projectSheet == nil }, set: { if !$0 { store.error = nil } })) {
            Button("Закрыть") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onExitCommand {
            if store.selectedID != nil { Task { await store.select(nil) } }
            else { store.query = ""; searchFocused = false }
        }
        .task { await store.connect() }
    }
    @ViewBuilder private var connectionBanner: some View {
        if let label = store.connectionLabel {
            HStack(alignment: .center, spacing: 10) {
                if case .disconnected = store.connectionState {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.status("waiting").2)
                } else { ProgressView().controlSize(.small) }
                Text(label).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if case .disconnected = store.connectionState {
                    Button("Проверить снова") { store.retry() }.buttonStyle(KabanButtonStyle())
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
                .background(theme.control).overlay(alignment: .bottom) { theme.line.frame(height: 0.5) }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("🐗").font(.system(size: 24))
                ReferenceWordmark().fill(theme.text).frame(width: 80, height: 24)
                Spacer()
            }.padding(.horizontal, 20).frame(height: 60)
            VStack(spacing: 3) {
                ForEach(BoardFilter.allCases, id: \.self) { filter in
                    Button {
                        store.screen = .board; store.filter = filter
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: filter == .all ? "rectangle.split.3x1" : filter == .waiting ? "hand.raised" : "light.beacon.max")
                                .foregroundStyle(filter == .incidents && (store.projection?.openIncidentCount ?? 0) > 0 ? theme.status("incident").0 : theme.accent)
                                .frame(width: 18)
                            Text(filter.rawValue).font(.system(size: 13, weight: store.filter == filter && store.screen == .board ? .semibold : .medium))
                            Spacer()
                            if filter != .all {
                                countBadge(filter == .waiting ? store.waitingCount : store.projection?.openIncidentCount ?? 0, attention: filter == .waiting)
                            }
                        }.padding(.horizontal, 10).frame(height: 34)
                            .background(store.screen == .board && store.filter == filter ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12)
            HStack {
                Text("Проекты").font(.system(size: 11, weight: .semibold)); Spacer()
                Text("\(store.projection?.projects.count ?? 0)").monospacedDigit()
                Button { store.beginProjectFlow(.add) } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).disabled(!store.can(.addProject)).help(store.can(.addProject) ? "Добавить проект" : store.unavailableReason(.addProject)).accessibilityLabel("Добавить проект")
            }
                .foregroundStyle(theme.faint).padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.projection?.projectOrder ?? [], id: \.self) { id in
                        if let project = store.projection?.projects[id] { projectRow(project) }
                    }
                    Text("Покажите проект на доске через его меню.")
                        .font(.system(size: 11)).foregroundStyle(theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 8)
                }.padding(.horizontal, 12)
            }
            macCard.padding(12)
        }
        .background(theme.dark ? Color(hex: 0x24242b).opacity(0.88) : Color.white.opacity(0.52))
    }
    private func projectRow(_ project: ProjectSummary) -> some View {
        let id = project.id
        return Button {
            store.selectedProjectID = id; store.screen = .board; store.filter = .all
            if !store.visibleIDs.contains(id) { store.show(id) }
        } label: {
            HStack(spacing: 10) {
                ReferenceMascot(emoji: store.mascot(id).emoji, theme: theme, state: store.projectStatus(id), size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(store.projectCaption(id)).font(.system(size: 10.5)).foregroundStyle(theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if project.openIncidentCount > 0 { countBadge(project.openIncidentCount, attention: false) }
                else if !store.visibleIDs.contains(id) { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(theme.faint) }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(store.selectedProjectID == id ? theme.control.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Новая задача") { store.beginCreation(id) }
                    .disabled(!store.can(.createTask)).help(store.unavailableReason(.createTask))
                Button("Настройки проекта") { store.screen = .project(id) }
                Button("Переподключить папку…") { store.beginProjectFlow(.relink(id)) }.disabled(!store.session.can(.relinkProject(projectId: id, path: project.path)))
                Button("Удалить из Kaban…", role: .destructive) { store.beginProjectFlow(.remove(id)) }.disabled(!store.session.can(.removeProject(projectId: id)))
                Divider()
                if store.visibleIDs.contains(id) { Button("Скрыть с доски") { store.hide(id) } }
                else { Button("Показать на доске") { store.show(id) } }
            }
            .accessibilityLabel("\(project.name), \(store.projectCaption(id))")
    }
    private func countBadge(_ count: Int, attention: Bool) -> some View {
        Text("\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(count > 0 && attention ? Color.white : theme.secondary)
            .padding(.horizontal, 5).frame(height: 16)
            .background(count > 0 && attention ? theme.status("waiting").0 : theme.control, in: Capsule())
    }
    private func header(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            KabanIconButton(symbol: "sidebar.left", help: "Показать или скрыть проекты") { sidebarVisible.toggle() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .bold))
                Text(store.screen == .board ? "\(DesignSystem.projectCount(store.visibleIDs.count)) на доске" : "Kaban · \(store.selectedProjectID.flatMap { store.projection?.projects[$0]?.name } ?? "")")
                    .font(.system(size: 10.5)).foregroundStyle(theme.faint)
            }.fixedSize(horizontal: true, vertical: false)
            if store.screen == .board {
                KabanSegments(selection: $byStage, options: [(false, "Дорожки"), (true, "По стадиям")])
                    .frame(width: width < 900 ? 164 : 192)
            }
            Spacer(minLength: 8)
            if store.screen == .board {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.faint)
                    TextField("Поиск задач", text: $store.query).textFieldStyle(.plain).focused($searchFocused)
                        .font(.system(size: 11))
                    if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(theme.faint) }
                }.padding(.horizontal, 9).frame(width: width < 900 ? 120 : 145, height: 30).background(theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                if width >= 900 { Label("\(store.runningCount)", systemImage: "cpu").font(.system(size: 11)).foregroundStyle(theme.secondary).help("Активные задачи") }
                Button { store.beginCreation() } label: { Label("Задача", systemImage: "plus") }
                    .buttonStyle(KabanButtonStyle(primary: true))
                    .disabled(!store.can(.createTask) || store.selectedProjectID == nil || store.creation.commandID != nil)
                    .help(store.can(.createTask) ? "Новая задача · ⌘N" : store.unavailableReason(.createTask))
            } else {
                Button("К доске") { store.screen = .board }.buttonStyle(KabanButtonStyle())
            }
        }.padding(.horizontal, 16).frame(height: 60)
            .background(theme.window.opacity(0.35))
    }
    private func board(width: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.projection == nil { ProgressView("Загрузка доски…").frame(width: max(width - 24, 0), height: 280) }
                    else if lanes.isEmpty { emptyBoard.frame(width: max(width - 24, 0), height: 280) }
                    else if byStage {
                        stagesBoard(width: max(width - 24, 1080))
                    } else {
                        ForEach(lanes, id: \.project.id) { lane in
                            laneView(lane, width: max(width - 24, CGFloat(lane.columns.count) * 154 + 20))
                        }
                    }
                }.padding(12)
            }.scrollIndicators(.automatic)
            if store.selectedID != nil {
                TaskDetailView(store: store, openSheet: { store.sheet = $0 })
                    .frame(width: min(500, max(width - 24, 0)))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.strongLine, lineWidth: 0.5))
                    .shadow(color: .black.opacity(theme.dark ? 0.45 : 0.18), radius: 20, y: 8)
                    .padding(12)
            }
        }
    }
    private var emptyBoard: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 32)).foregroundStyle(theme.faint)
            Text("Доска пуста").font(.system(size: 18, weight: .semibold))
            Text(store.projection?.projects.isEmpty == true ? "Подключите git-репозиторий, чтобы завести первую задачу." : "Выберите проект слева, чтобы показать его задачи.").font(.system(size: 12)).foregroundStyle(theme.secondary)
            if store.projection?.projects.isEmpty == true {
                Button("Добавить проект…") { store.beginProjectFlow(.add) }.buttonStyle(KabanButtonStyle(primary: true)).disabled(!store.can(.addProject))
            }
        }.frame(maxWidth: .infinity)
    }
    private func laneView(_ lane: BoardLane, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if collapsed.contains(lane.project.id) { collapsed.remove(lane.project.id) } else { collapsed.insert(lane.project.id) }
                } label: { Image(systemName: collapsed.contains(lane.project.id) ? "chevron.right" : "chevron.down").frame(width: 16, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(theme.faint).help("Свернуть или раскрыть проект")
                ReferenceMascot(emoji: store.mascot(lane.project.id).emoji, theme: theme, state: store.projectStatus(lane.project.id), size: 24)
                Text(lane.project.name).font(.system(size: 13, weight: .semibold))
                ReferenceChip(title: "⑂ " + lane.project.baseBranch, theme: theme, mono: true)
                Text(store.projectCaption(lane.project.id)).font(.system(size: 11)).foregroundStyle(theme.faint).lineLimit(1)
                Spacer()
                if lane.project.openIncidentCount > 0 { Label("\(lane.project.openIncidentCount) инцидент", systemImage: "light.beacon.max").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.status("incident").2) }
                Button { store.beginCreation(lane.project.id) } label: { Image(systemName: "plus") }
                    .disabled(!store.can(.createTask))
                    .buttonStyle(.plain).help(store.can(.createTask) ? "Новая задача в \(lane.project.name)" : store.unavailableReason(.createTask)).frame(width: 24, height: 28)
                Button { store.selectedProjectID = lane.project.id; store.screen = .project(lane.project.id) } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help("Настройки проекта").frame(width: 24, height: 28)
                Button { store.hide(lane.project.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Убрать с доски").foregroundStyle(theme.faint).frame(width: 24, height: 28)
            }.padding(.horizontal, 8).frame(height: 38)
            if !collapsed.contains(lane.project.id) {
                if let pipeline = store.projection?.pipelines[lane.project.id], !pipeline.isValid {
                    Label("Пайплайн не запустится: \(pipeline.issues.first(where: { $0.severity == .error })?.message ?? "нужна настройка")", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.status("waiting").2)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 8).padding(.bottom, 6)
                }
                HStack(alignment: .top, spacing: 6) {
                    ForEach(lane.columns, id: \.stage.id) { column in
                        columnView(column, project: lane.project)
                            .frame(width: columnWidth(column.stage, all: lane.columns.map(\.stage), available: width - 16))
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }
        }.frame(width: width)
            .background(theme.lane, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line, lineWidth: 0.5))
    }
    private func columnWidth(_ stage: StageSummary, all: [StageSummary], available: CGFloat) -> CGFloat {
        let units = all.map { weight($0) }.reduce(0, +)
        return (available - CGFloat(max(all.count - 1, 0)) * 6) * weight(stage) / max(units, 1)
    }
    private func weight(_ stage: StageSummary) -> CGFloat {
        switch stage.kind { case .queue, .merge, .terminal: 0.76; default: 1.2 }
    }
    private func columnView(_ column: BoardColumn, project: ProjectSummary) -> some View {
        let ids = column.taskIds.filter { store.matches($0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: DesignSystem.symbol(column.stage)).foregroundStyle(theme.status(DesignSystem.tone(column.stage)).0)
                Text(column.stage.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 0)
                if let load = store.projection?.load(projectId: project.id, stageId: column.stage.id), let limit = load.wipLimit {
                    Text("\(load.wipUsed)/\(limit)").monospacedDigit().padding(.horizontal, 5).background(theme.control, in: Capsule())
                        .help("Занятые места и WIP-лимит")
                } else { Text("\(column.taskIds.count)").foregroundStyle(theme.faint).monospacedDigit() }
            }.font(.system(size: 11)).frame(height: 24).padding(.horizontal, 3)
            if let model = column.stage.model {
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.system(size: 9))
                    Text(model.rawValue).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 0)
                }.foregroundStyle(theme.faint).padding(.horizontal, 3).frame(height: 14)
            }
            if ids.isEmpty {
                Text(column.taskIds.isEmpty ? "Пусто" : "Нет совпадений").font(.system(size: 11)).foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.strongLine, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
            }
            ForEach(ids, id: \.self) { id in
                if let card = store.projection?.tasks[id] { taskButton(card, project: project) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 5).padding(.bottom, 6).frame(minHeight: 180, alignment: .topLeading)
            .background(theme.column, in: RoundedRectangle(cornerRadius: 10))
    }
    private func taskButton(_ card: TaskCard, project: ProjectSummary) -> some View {
        Button { Task { await store.select(card.id) } } label: {
            TaskCardView(card: card, mascot: store.mascot(project.id), selected: store.selectedID == card.id, pendingLabel: store.pendingLabel(.task(card.id)))
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Открыть детали") { Task { await store.select(card.id) } }
                if TaskActions.canEdit(card) {
                    Button("Изменить…") {
                        store.editorError = nil
                        Task {
                            await store.select(card.id)
                            if let detail = store.detail, detail.task.id == card.id, TaskActions.canEdit(detail.task) { store.sheet = .edit(detail.task, detail.body) }
                        }
                    }.disabled(!store.can(.editTask)).help(store.unavailableReason(.editTask))
                }
                if TaskActions.canCancel(card) {
                    Button("Перенести…") { store.sheet = .move(card) }.disabled(!store.can(.moveTask)).help(store.unavailableReason(.moveTask))
                    Button("Отменить…", role: .destructive) { store.sheet = .cancel(card) }.disabled(!store.can(.cancelTask)).help(store.unavailableReason(.cancelTask))
                }
            }
    }
    private func stagesBoard(width: CGFloat) -> some View {
        let stages = lanes.flatMap(\.columns).map(\.stage).reduce(into: [StageSummary]()) { stages, stage in if !stages.contains(where: { $0.id == stage.id }) { stages.append(stage) } }
        return HStack(alignment: .top, spacing: 8) {
            ForEach(stages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: 12) {
                    Label(stage.name, systemImage: DesignSystem.symbol(stage)).font(.system(size: 13, weight: .semibold))
                    ForEach(lanes, id: \.project.id) { lane in
                        if let column = lane.columns.first(where: { $0.stage.id == stage.id }) {
                            Text(lane.project.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.faint)
                            columnView(column, project: lane.project)
                        }
                    }
                }.padding(10).frame(width: max((width - CGFloat(stages.count - 1) * 8) / CGFloat(max(stages.count, 1)), 140))
                    .background(theme.lane, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    private var macCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Этот Мак", systemImage: "cpu").font(.system(size: 12, weight: .semibold)); Spacer(); KabanIconButton(symbol: "slider.horizontal.3", help: "Квота и агенты") { store.screen = .quota } }
            HStack { Text("Активные задачи"); Spacer(); Text("\(store.runningCount)").fontWeight(.semibold).monospacedDigit() }.font(.system(size: 11))
            theme.line.frame(height: 0.5)
            quotaRows
            Text(store.dataSource).font(.system(size: 10)).foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true).help(store.dataSourceDetail)
        }.padding(12).background(theme.lane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 0.5))
    }
    private var quotaRows: some View {
        VStack(spacing: 8) {
            ForEach([ModelPool.cm, .om], id: \.self) { pool in
                HStack(spacing: 8) {
                    Text(pool.rawValue.capitalized).font(.system(size: 10, weight: .semibold)).frame(width: 20, alignment: .leading)
                    if let quota = store.projection?.ephemeral.quota, !quota.isStale(now: Date()), let percent = quota.percentUsed(pool) {
                        ProgressView(value: percent, total: 100).tint(pool == .cm ? theme.status("gating").0 : theme.status("waiting").0)
                        Text("\(Int(percent))%").font(.system(size: 10)).monospacedDigit()
                    } else { Text("Нет данных").font(.system(size: 11)).foregroundStyle(theme.faint); Spacer() }
                }
            }
        }
    }
    private var quotaPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Квота Cursor", systemImage: "gauge.with.dots.needle.50percent").font(.system(size: 22, weight: .bold))
                Text("Расход по пулам моделей").font(.system(size: 13)).foregroundStyle(theme.secondary)
                quotaRows.padding(20).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
                Text("Данные квоты появятся после подключения источника состояния.").font(.system(size: 12)).foregroundStyle(theme.secondary)
            }.frame(maxWidth: 640, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct TaskCardView: View {
    let card: TaskCard
    var mascot: MascotPick = MascotKit.pick(seed: "kaban")
    let selected: Bool
    let pendingLabel: String?
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var presentation: CardPresentation { .init(state: card.state) }
    var body: some View {
        let colors = theme.status(presentation.tone.rawValue)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(mascot.emoji).font(.system(size: 11))
                    Text(card.id.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if card.priority > 0 { Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.faint) }
                }
                Text(card.title).font(.system(size: 12, weight: .medium)).lineSpacing(1).lineLimit(3)
                    .strikethrough(card.state == .cancelled).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(card.state == .done || card.state == .cancelled ? theme.secondary : theme.text)
                ForEach(Array(card.suspiciousFiles.prefix(2)), id: \.path) { file in
                    Text(file.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(colors.2).lineLimit(1).truncationMode(.middle)
                }
                if card.suspiciousFiles.count > 2 { Text("+\(card.suspiciousFiles.count - 2) файла").font(.system(size: 10)).foregroundStyle(colors.2) }
                if let reason = card.bounceByReason.keys.sorted().first, let count = card.bounceByReason[reason], count > 0 {
                    ReferenceChip(title: "↩ \(count) возврата", theme: theme, tone: "running")
                }
            }.padding(.init(top: 8, leading: 11, bottom: 8, trailing: 8))
            HStack(spacing: 4) {
                Image(systemName: pendingLabel != nil ? "paperplane" : presentation.symbol).font(.system(size: 10))
                Text(pendingLabel ?? presentation.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if card.attempt > 0, let limit = card.maxAttempts { Text("\(card.attempt)/\(limit)").font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.faint).fixedSize() }
            }.padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(presentation.tone == .incident ? Color.white : colors.2)
                .background(presentation.tone == .incident ? colors.0 : colors.1.opacity(presentation.tone == .queued ? 0.25 : 1))
                .overlay(alignment: .top) { theme.line.frame(height: 0.5) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.card)
        .overlay(alignment: .leading) { ProjectEdgeTexture(texture: mascot.texture, color: theme.faint).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? theme.accent : [.waiting, .review, .incident].contains(presentation.tone) ? colors.0.opacity(0.35) : theme.line, lineWidth: selected ? 2 : 0.5))
        .shadow(color: .black.opacity(theme.dark ? 0.22 : 0.06), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.id.rawValue), \(card.title), \(presentation.label)\(pendingLabel.map { ", " + $0 } ?? "")")
    }
}

struct ProjectEdgeTexture: View {
    let texture: EdgeTexture
    let color: Color
    var body: some View {
        Canvas { context, size in
            for y in stride(from: 0.0, to: size.height + 5, by: 5) {
                switch texture {
                case .dots: context.fill(Path(ellipseIn: .init(x: 0.5, y: y, width: 2, height: 2)), with: .color(color))
                case .solidThin: context.fill(Path(CGRect(x: 0, y: y, width: 2, height: 5)), with: .color(color.opacity(0.65)))
                case .grid, .crosshatch: context.fill(Path(CGRect(x: 0, y: y, width: 3, height: 2)), with: .color(color))
                default:
                    var path = Path(); path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: 3, y: y + 3))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
            }
        }.accessibilityHidden(true)
    }
}

struct TaskDetailView: View {
    @Bindable var store: BoardStore
    let openSheet: (TaskSheetRoute) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var tab = "Описание"
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let detail = store.detail {
                detailHeader(detail)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !detail.suspiciousFiles.isEmpty { suspiciousBlock(detail) }
                        if detail.task.state == .waitingHuman(.incident) {
                            Label("Обнаружен инцидент", systemImage: "light.beacon.max").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.status("incident").2).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.status("incident").1, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if tab == "Описание" {
                            Text("Описание и критерии приёмки").font(.system(size: 12, weight: .semibold))
                            if let body = detail.body {
                                if body.isEmpty { Text("Описание пока пустое").font(.system(size: 12)).foregroundStyle(theme.faint) }
                                else { TaskMarkdownView(source: body) }
                            } else { Text("Описание недоступно").font(.system(size: 12)).foregroundStyle(theme.faint) }
                        } else if tab == "Лента" {
                            if detail.feed.isEmpty { Text("Событий пока нет").font(.system(size: 12)).foregroundStyle(theme.faint) }
                            ForEach(detail.feed, id: \.id) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "clock").foregroundStyle(theme.faint).frame(width: 24, height: 24).background(theme.control, in: RoundedRectangle(cornerRadius: 7))
                                    Text(item.text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.at, style: .time).font(.system(size: 10)).foregroundStyle(theme.faint)
                                }.padding(.vertical, 6)
                                Divider()
                            }
                        } else {
                            if detail.runs.isEmpty { Text("Запусков пока нет").font(.system(size: 12)).foregroundStyle(theme.faint) }
                            ForEach(detail.runs, id: \.id) { run in
                                HStack { Text("Попытка \(run.number)"); Spacer(); Text(run.requestedModel.rawValue).font(.system(size: 11, design: .monospaced)) }.font(.system(size: 12))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                detailActions(detail).padding(12).background(theme.window)
            } else {
                HStack { Text("Задача").font(.headline); Spacer(); closeButton }.padding(16)
                ProgressView("Загрузка…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(theme.dark ? Color(hex: 0x242429) : Color(hex: 0xfcfcfe))
            .onChange(of: store.selectedID) { _, _ in tab = "Описание" }
    }
    private var closeButton: some View { KabanIconButton(symbol: "xmark", help: "Закрыть детали · Esc") { Task { await store.select(nil) } } }
    private func detailHeader(_ detail: TaskDetail) -> some View {
        let task = detail.task
        let presentation = CardPresentation(state: task.state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(store.mascot(task.projectId).emoji)
                Text(task.id.rawValue).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle)
                Text(store.projection?.projects[task.projectId]?.name ?? "").font(.system(size: 11)).foregroundStyle(theme.faint)
                Spacer(); closeButton
            }
            Text(task.title).font(.system(size: 18, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(presentation.label, systemImage: presentation.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.status(presentation.tone.rawValue).2).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.status(presentation.tone.rawValue).1, in: RoundedRectangle(cornerRadius: 6))
                if let model = task.model { ReferenceChip(title: model.rawValue, theme: theme, mono: true) }
                Spacer(minLength: 0)
            }
            if let branch = task.branch { Label(branch, systemImage: "arrow.triangle.branch").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            KabanSegments(selection: $tab, options: [("Описание", "Описание"), ("Лента", "Лента"), ("Запуски", "Запуски")])
        }.padding(16).overlay(alignment: .bottom) { theme.line.frame(height: 0.5) }
    }
    private func suspiciousBlock(_ detail: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Подозрительные файлы · \(detail.suspiciousFiles.count)", systemImage: "exclamationmark.shield")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.status("waiting").2)
            Text("Проверьте файлы перед следующим действием.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            ForEach(detail.suspiciousFiles, id: \.path) { file in
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(file.rule == .pattern ? "по шаблону \(file.pattern ?? "—")" : "превышен лимит размера")
                        Spacer(); Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                    }.font(.system(size: 10)).foregroundStyle(theme.secondary)
                }.padding(9).background(theme.card, in: RoundedRectangle(cornerRadius: 7))
            }
        }.padding(12).background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.status("waiting").0.opacity(0.4), lineWidth: 0.5))
    }
    private func detailActions(_ detail: TaskDetail) -> some View {
        HStack(spacing: 8) {
            if detail.task.state == .running {
                Button { Task { await store.send(.pauseTask(taskId: detail.task.id), taskID: detail.task.id) } } label: { Label("Пауза", systemImage: "pause") }.buttonStyle(KabanButtonStyle()).disabled(!store.can(.pauseTask)).help(store.unavailableReason(.pauseTask))
            } else if detail.task.state == .paused {
                Button { Task { await store.send(.resumeTask(taskId: detail.task.id), taskID: detail.task.id) } } label: { Label("Продолжить", systemImage: "play") }.buttonStyle(KabanButtonStyle(primary: true)).disabled(!store.can(.resumeTask)).help(store.unavailableReason(.resumeTask))
            }
            if TaskActions.canEdit(detail.task) {
                Button("Изменить…") { store.editorError = nil; openSheet(.edit(detail.task, detail.body)) }.buttonStyle(KabanButtonStyle()).disabled(!store.can(.editTask)).help(store.unavailableReason(.editTask))
            }
            Spacer(minLength: 0)
            if TaskActions.canCancel(detail.task) {
                Menu {
                    Button("Перенести…") { openSheet(.move(detail.task)) }.disabled(!store.can(.moveTask))
                    Button("Отменить задачу…", role: .destructive) { openSheet(.cancel(detail.task)) }.disabled(!store.can(.cancelTask))
                } label: { Label("Действия", systemImage: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            if store.projection?.isSent(detail.task.id) == true { ProgressView().controlSize(.small) }
        }.disabled(store.projection?.isSent(detail.task.id) ?? false)
    }
}

struct ProjectSettingsView: View {
    @Bindable var store: BoardStore
    let projectID: ProjectID
    let theme: ReferenceTheme
    @State private var selectedStage: StageID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let project = store.projection?.projects[projectID] {
                    HStack(spacing: 12) {
                        ReferenceMascot(emoji: store.mascot(projectID).emoji, theme: theme, state: store.projectStatus(projectID), size: 40)
                        VStack(alignment: .leading, spacing: 4) { Text(project.name).font(.system(size: 22, weight: .bold)); Text(project.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary).textSelection(.enabled) }
                    }
                    settingsSection("Папка проекта") {
                        if project.availability == .missing { Text("Папка недоступна. Выберите её новый путь или удалите проект из Kaban.").font(.system(size: 12)).foregroundStyle(theme.status("waiting").2) }
                        HStack {
                            Button("Переподключить папку…") { store.beginProjectFlow(.relink(projectID)) }.buttonStyle(KabanButtonStyle()).disabled(!store.session.can(.relinkProject(projectId: projectID, path: project.path)))
                            Button("Проверить снова") { Task { await store.session.send(.recheck(scope: .project(projectId: projectID))) } }.buttonStyle(KabanButtonStyle()).disabled(!store.session.can(.recheck(scope: .project(projectId: projectID))) || store.capabilities?.commands.first { $0.name == CommandName.recheck.rawValue }?.scopes?.contains("project") != true)
                            Spacer(minLength: 8)
                            Button("Удалить из Kaban…") { store.beginProjectFlow(.remove(projectID)) }.buttonStyle(KabanButtonStyle()).disabled(!store.session.can(.removeProject(projectId: projectID)))
                        }
                        if let pending = store.pendingLabel(.project(projectID)) { Text(pending).font(.system(size: 12)).foregroundStyle(theme.secondary) }
                    }
                    settingsSection("Проект") {
                        settingsRow("Основная ветка", project.baseBranch)
                        settingsRow("Вес проекта", "\(project.weight)")
                        settingsRow("Процессов одновременно", project.maxRuns.map(String.init) ?? "Нет данных")
                        settingsRow("Автор коммитов", project.identity.map { "\($0.name) <\($0.email)>" } ?? "Нет данных")
                    }
                    if let pipeline = store.projection?.pipelines[projectID] {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Пайплайн").font(.system(size: 13, weight: .semibold))
                            Text("Изменения настроек будут доступны после подключения бэка.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                            ScrollView(.horizontal) {
                                HStack(spacing: 6) {
                                    ForEach(pipeline.stages.sorted { $0.display.order < $1.display.order }, id: \.id) { stage in
                                        Button { selectedStage = stage.id } label: { Label(stage.name, systemImage: DesignSystem.symbol(stage)) }
                                            .buttonStyle(KabanButtonStyle(primary: (selectedStage ?? pipeline.stages.first?.id) == stage.id, compact: true))
                                    }
                                }.padding(.vertical, 2)
                            }
                        }
                        if let stage = pipeline.stages.first(where: { $0.id == (selectedStage ?? pipeline.stages.first?.id) }) {
                            settingsSection(stage.name) {
                                settingsRow("Модель", stage.model?.rawValue ?? (stage.kind == .agent ? "Не задана" : "Не применяется"))
                                settingsRow("WIP-лимит", stage.wip.map(String.init) ?? "Нет данных")
                                settingsRow("Максимум попыток", stage.maxAttempts.map(String.init) ?? "Нет данных")
                                settingsRow("Только чтение", stage.readOnly ? "Да" : "Нет")
                                settingsRow("Гейты", stage.gates.isEmpty ? "Не заданы" : stage.gates.joined(separator: ", "))
                            }
                        }
                        settingsSection("Git-политика") {
                            settingsRow("Пресет", pipeline.gitPreset == .strict ? "Строгий" : pipeline.gitPreset == .standard ? "Стандартный" : "Свободный")
                            if let policy = pipeline.projectGitPolicy {
                                settingsRow("Разрешено", policy.allowed.map(\.rule).joined(separator: ", "))
                                settingsRow("Запрещено", policy.denied.map(\.rule).joined(separator: ", "))
                            } else { settingsRow("Эффективная политика", "Нет данных") }
                        }
                    }
                }
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(16)
            Divider()
            VStack(spacing: 14) { content() }.padding(16)
        }.background(theme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 0.5))
    }
    private func settingsRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.system(size: 12)).foregroundStyle(theme.secondary).frame(width: 180, alignment: .leading)
            Text(value).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
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
    @State private var baseCard: TaskCard?
    @State private var keepBranch = false
    @State private var targetID: StageID?
    @FocusState private var titleFocused: Bool
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }

    init(store: BoardStore, route: TaskSheetRoute) {
        self.store = store; self.route = route
        let key: TaskDraftKey?
        switch route { case .create(let id): key = .create(id); case .edit(let card, _): key = .edit(card.id); default: key = nil }
        let saved = key.flatMap { store.session.drafts?.record(for: $0) }
        if case .edit(let task, let body) = route {
            _draft = State(initialValue: saved?.draft ?? DemoTaskDraft(title: task.title))
            _exactBody = State(initialValue: saved?.exactBody ?? body ?? "")
            _baseCard = State(initialValue: saved?.baseCard ?? task)
        } else {
            _draft = State(initialValue: saved?.draft ?? DemoTaskDraft())
            _baseCard = State(initialValue: nil)
        }
    }
    private var draftKey: TaskDraftKey? {
        switch route { case .create(let id): .create(id); case .edit(let task, _): .edit(task.id); default: nil }
    }
    private func saveDraft() {
        guard let key = draftKey, !pending else { return }
        do { try store.session.drafts?.save(.init(key: key, draft: draft, exactBody: bodyKnown || store.session.drafts?.record(for: key)?.exactBody != nil ? exactBody : nil, baseCard: baseCard)) }
        catch { store.editorError = "Не удалось сохранить черновик. \(error.localizedDescription)" }
    }
    private var card: TaskCard? {
        switch route { case .edit(let card, _), .move(let card), .cancel(let card): card; case .create: nil }
    }
    private var stale: Bool {
        guard let card else { return false }
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
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
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
                    if stale {
                        Text("Задача изменилась. Черновик сохранён; откройте действие снова, чтобы сверить изменения.").font(.callout).foregroundStyle(theme.secondary)
                        if case .edit = route {
                            Button("Удалить сохранённый черновик") {
                                if let key = draftKey { try? store.session.drafts?.discard(key) }
                                dismiss()
                            }.buttonStyle(KabanButtonStyle())
                        }
                    }
                    if let label = pendingText { Text(label + " Можно закрыть окно — отправка сохранена.").font(.callout).foregroundStyle(theme.secondary) }
                    else if !store.canSend { Text("Черновик сохранён. Отправка будет доступна после синхронизации.").font(.callout).foregroundStyle(theme.secondary) }
                    if let error = store.editorError { Text(error).font(.callout).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: formHeight)
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction)
                Button(pending ? "Ожидаем…" : actionLabel) { Task { await submit() } }
                    .buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(pending || stale || !canSubmit || !store.can(actionCommand))
            }
        }.padding(24).frame(width: 560).background(theme.window)
            .onAppear { titleFocused = true }
            .onChange(of: draft) { _, _ in saveDraft() }
            .onChange(of: exactBody) { _, _ in saveDraft() }
    }
    private var formHeight: CGFloat {
        switch route { case .create, .edit: 420; case .move: 310; case .cancel: 180 }
    }
    private var pendingText: String? {
        switch route { case .create(let id): store.pendingLabel(.project(id)); default: card.flatMap { store.pendingLabel(.task($0.id)) } }
    }
    private var actionCommand: CommandName {
        switch route { case .create: .createTask; case .edit: .editTask; case .move: .moveTask; case .cancel: .cancelTask }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Заголовок", text: $draft.title).textFieldStyle(.roundedBorder).focused($titleFocused)
            if case .edit = route {
                Text("Описание и критерии приёмки · Markdown").font(.headline)
                markdownEditor($exactBody, height: 220).disabled(!bodyKnown)
            } else {
                Text("Описание · Markdown").font(.headline)
                markdownEditor($draft.description, height: 110)
                Text("Критерии приёмки").font(.headline)
                markdownEditor($draft.acceptanceCriteria, height: 110)
            }
            if !bodyKnown { Text("Описание недоступно. Можно изменить только заголовок.").font(.caption).foregroundStyle(.secondary) }
            else if case .create = route, !draft.hasAcceptanceCriteria { Text("Без критериев приёмки задача останется в Backlog.").font(.caption).foregroundStyle(.secondary) }
        }.disabled(pending || stale)
    }
    private func markdownEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 12)).scrollContentBackground(.hidden)
            .padding(8).frame(height: height).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.strongLine, lineWidth: 0.5))
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
        saveDraft()
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
