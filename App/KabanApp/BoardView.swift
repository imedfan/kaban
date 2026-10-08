import SwiftUI
import KabanProtocol
import KabanBoardCore

enum BoardScreen: Equatable { case board, project(ProjectID), quota }
enum BoardFilter: String, CaseIterable { case all = "Доска", waiting = "Ждут человека", incidents = "Инциденты", hiddenStages = "Скрытые стадии" }

struct BoardView: View {
    @Bindable var store: BoardStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || BoardQA.argument("--qa-reduce-motion") == "yes" }
    @State private var sidebarVisible = true
    @State private var collapsed: Set<ProjectID> = []
    @State private var dropTarget: ProjectID?
    @State private var endDropTarget = false
    @State private var stageCollapsed: [BoardStageKey: Bool] = [:]
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
                    if let notice = store.taskDropNotice {
                        HStack(spacing: 8) {
                            Label(notice, systemImage: "info.circle").font(.callout)
                            Spacer()
                            KabanIconButton(symbol: "xmark", help: "Закрыть сообщение о переносе") { store.taskDropNotice = nil }
                        }.foregroundStyle(theme.secondary).padding(.horizontal, 18).padding(.vertical, 8).background(theme.control)
                    }
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
        .sheet(item: $store.sheet) { TaskActionSheet(store: store, route: $0).id($0.id) }
        .sheet(item: $store.reviewRoute) { HumanReviewSheet(store: store, route: $0) }
        .sheet(item: $store.overlapRoute) { OverlapSheet(store: store, route: $0) }
        .sheet(item: $store.controlSheet) { TaskControlSheet(store: store, route: $0) }
        .sheet(item: $store.projectSheet) { ProjectLifecycleSheet(store: store, route: $0) }
        .popover(isPresented: Binding(get: { store.mascotProjectID != nil }, set: { if !$0 { store.mascotProjectID = nil } })) { if let id = store.mascotProjectID { MascotPickerView(store: store, projectID: id) } }
        .onChange(of: store.projection?.projectOrder) { _, ids in
            if case .project(let id) = store.screen, ids?.contains(id) != true { store.screen = .board }
        }
        .onChange(of: store.createdTaskID) { _, id in
            if let id, case .create(let project) = store.sheet,
               store.projection?.tasks[id]?.projectId == project,
               store.session.drafts?.record(for: .create(project)) == nil { store.sheet = nil }
        }
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
                            Image(systemName: filter == .all ? "rectangle.split.3x1" : filter == .waiting ? "hand.raised" : filter == .hiddenStages ? "eye.slash" : "light.beacon.max")
                                .foregroundStyle(filter == .incidents && (store.projection?.openIncidentCount ?? 0) > 0 ? theme.status("incident").0 : theme.accent)
                                .frame(width: 18)
                            Text(filter.rawValue).font(.system(size: 13, weight: store.filter == filter && store.screen == .board ? .semibold : .medium))
                            Spacer()
                            if filter != .all {
                                countBadge(filter == .waiting ? store.waitingCount : filter == .hiddenStages ? store.hiddenStageCount : store.projection?.openIncidentCount ?? 0, attention: filter == .waiting)
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
                    if (store.projection?.projectOrder ?? []).contains(where: { !store.visibleIDs.contains($0) }) {
                        Text("Покажите проект на доске через его меню.")
                            .font(.system(size: 11)).foregroundStyle(theme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 8)
                    }
                }.padding(.horizontal, 12)
            }
            macCard.padding(12)
        }
        .background(theme.dark ? Color(hex: 0x24242b).opacity(0.88) : Color.white.opacity(0.52))
    }
    private func projectRow(_ project: ProjectSummary) -> some View {
        let id = project.id
        return Button {
            store.filter = .all; store.focusProject(id)
        } label: {
            HStack(spacing: 10) {
                ReferenceMascot(emoji: store.mascot(id).emoji, theme: theme, state: store.projectStatus(id), size: 28, completionTrigger: store.completionTrigger(id))
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(store.projectCaption(id)).font(.system(size: 10.5)).foregroundStyle(theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                let badges = store.projection?.badgeCounts(for: id)
                if let count = badges?.waitingHuman, count > 0 { countBadge(count, attention: true).help("Ждут человека") }
                if project.openIncidentCount > 0 { countBadge(project.openIncidentCount, attention: false).help("Открытые инциденты") }
                if !store.visibleIDs.contains(id) { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(theme.faint) }
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(store.selectedProjectID == id ? theme.control.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Новая задача") { store.beginCreation(id) }
                    .disabled(!store.can(.createTask)).help(store.unavailableReason(.createTask))
                Button("Настройки проекта") { store.selectedProjectID = id; store.screen = .project(id) }
                Button("Переподключить папку…") { store.beginProjectFlow(.relink(id)) }.disabled(!store.session.can(.relinkProject(projectId: id, path: project.path)))
                Button("Удалить из Kaban…", role: .destructive) { store.beginProjectFlow(.remove(id)) }.disabled(!store.session.can(.removeProject(projectId: id)))
                Button("Выбрать маскота…") { store.mascotProjectID = id }.disabled(!store.session.can(.setMascot(projectId: id, seed: project.mascotSeed)))
                Divider()
                if store.visibleIDs.contains(id) {
                    Button("Дорожка выше") { store.moveProject(id, by: -1) }.disabled(store.visibleIDs.first == id)
                    Button("Дорожка ниже") { store.moveProject(id, by: 1) }.disabled(store.visibleIDs.last == id)
                }
                if store.visibleIDs.contains(id) { Button("Скрыть с доски") { store.hide(id) } }
                else { Button("Показать на доске") { store.show(id) } }
            }
            .draggable("kaban-project:" + id.rawValue)
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
            }.frame(maxWidth: 200, alignment: .leading)
            if store.screen == .board {
                KabanSegments(selection: $store.compactBoard, options: [(false, "Дорожки"), (true, "По типу")])
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
                if width >= 900 { Label("\(store.reservationCount)", systemImage: "clock").font(.system(size: 11)).foregroundStyle(theme.secondary).help("Зарезервированные запуски. Наличие процесса не подтверждено.") }
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
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    if store.projection == nil { ProgressView("Загрузка доски…").frame(width: max(width - 24, 0), height: 280) }
                    else if lanes.isEmpty { emptyBoard.frame(width: max(width - 24, 0), height: 280) }
                    else if store.hasTaskFilter && store.visibleMatchCount == 0 {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                            Text("Задачи не найдены").font(.headline)
                            Text("В показанных стадиях нет совпадений по запросу и фильтру.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Сбросить поиск и фильтр") { store.query = ""; store.filter = .all }
                                .buttonStyle(KabanButtonStyle())
                        }.frame(width: max(width - 24, 0), height: 280)
                    }
                    else if store.compactBoard {
                        stagesBoard(width: max(width - 24, 0))
                    } else {
                        ForEach(lanes, id: \.project.id) { lane in
                            Section {
                                if !collapsed.contains(lane.project.id) { laneBody(lane, width: max(width - 24, 0)) }
                            } header: { laneHeader(lane, width: width).id(lane.project.id) }
                                .dropDestination(for: String.self) { values, _ in store.dropProject(values, before: lane.project.id) } isTargeted: { active in dropTarget = active ? lane.project.id : dropTarget == lane.project.id ? nil : dropTarget }
                        }
                    }
                    if !lanes.isEmpty && !(store.hasTaskFilter && store.visibleMatchCount == 0) {
                        Text("Перетащите проект сюда, чтобы поставить его последним")
                            .font(.system(size: 11)).foregroundStyle(theme.faint).frame(maxWidth: .infinity).padding(14)
                            .background(endDropTarget ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .dropDestination(for: String.self) { values, _ in store.dropProject(values, before: nil) } isTargeted: { endDropTarget = $0 }
                    }
                }.padding(12)
            }.scrollIndicators(.automatic)
            .onChange(of: store.focusRequest) { _, _ in
                if let id = store.selectedProjectID { collapsed.remove(id); if reduceMotion { proxy.scrollTo(id, anchor: .top) } else { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
            }
            }
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
            .dropDestination(for: String.self) { values, _ in store.dropProject(values, before: nil) }
    }
    private func columns(_ lane: BoardLane) -> [BoardColumn] {
        lane.columns.filter { store.filter == .hiddenStages ? $0.stage.display.hidden : !$0.stage.display.hidden }
    }
    private func isCollapsed(_ stage: StageSummary, project: ProjectID) -> Bool {
        stageCollapsed[.init(projectID: project, stageID: stage.id)] ?? (stage.display.collapsed || stage.kind == .gate)
    }
    private func laneHeader(_ lane: BoardLane, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(theme.faint)
                .draggable("kaban-project:" + lane.project.id.rawValue).help("Переставить дорожку")
            Button {
                if collapsed.contains(lane.project.id) { collapsed.remove(lane.project.id) } else { collapsed.insert(lane.project.id) }
            } label: { Image(systemName: collapsed.contains(lane.project.id) ? "chevron.right" : "chevron.down").frame(width: 16, height: 28) }
                .buttonStyle(.plain).foregroundStyle(theme.faint).help("Свернуть или раскрыть проект")
            Button { store.mascotProjectID = lane.project.id } label: {
                ReferenceMascot(emoji: store.mascot(lane.project.id).emoji, theme: theme, state: store.projectStatus(lane.project.id), size: 24, completionTrigger: store.completionTrigger(lane.project.id))
            }.buttonStyle(.plain).disabled(!store.can(.setMascot)).help("Выбрать маскота")
            Text(lane.project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            ReferenceChip(title: "⑂ " + lane.project.baseBranch, theme: theme, mono: true)
            Text(store.projectCaption(lane.project.id)).font(.system(size: 11)).foregroundStyle(theme.faint).lineLimit(1)
            Spacer(minLength: 0)
            if width > 1080 {
                ReferenceChip(title: "вес \(lane.project.weight)", theme: theme)
                Text("Процессы —").font(.system(size: 10)).foregroundStyle(theme.faint).help("Служба не сообщает подтверждённые агентские процессы.")
            }
            if lane.project.openIncidentCount > 0 {
                Label("\(lane.project.openIncidentCount)", systemImage: "light.beacon.max").font(.system(size: 11)).foregroundStyle(theme.status("incident").2).help("Открытые инциденты")
            }
            Button { Task { await store.toggleProjectPause(lane.project.id) } } label: {
                Image(systemName: store.projectPaused(lane.project.id) ? "play.circle" : "pause.circle")
            }.buttonStyle(.plain).frame(width: 24, height: 28)
                .foregroundStyle(store.projectPaused(lane.project.id) ? theme.accent : theme.secondary)
                .disabled(!store.can(store.projectPaused(lane.project.id) ? .resumeProject : .pauseProject) || store.session.pending(in: .project(lane.project.id)) != nil)
                .help(store.projectPaused(lane.project.id) ? "Продолжить новые запуски проекта" : "Приостановить новые запуски проекта. Текущие продолжатся.")
            Button { store.beginCreation(lane.project.id) } label: { Image(systemName: "plus") }
                .disabled(!store.can(.createTask)).buttonStyle(.plain).help("Новая задача в \(lane.project.name)").frame(width: 24, height: 28)
            Button { store.selectedProjectID = lane.project.id; store.screen = .project(lane.project.id) } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Настройки проекта").frame(width: 24, height: 28)
            Button { store.hide(lane.project.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Убрать с доски").foregroundStyle(theme.faint).frame(width: 24, height: 28)
        }.padding(.horizontal, 10).frame(height: 40)
            .background(theme.lane, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.selectedProjectID == lane.project.id ? theme.accent.opacity(0.5) : theme.line, lineWidth: 0.5))
            .overlay(alignment: .top) { if dropTarget == lane.project.id { theme.accent.frame(height: 2).allowsHitTesting(false) } }
    }
    private func laneBody(_ lane: BoardLane, width: CGFloat) -> some View {
        let displayed = columns(lane)
        return VStack(alignment: .leading, spacing: 6) {
            if let issue = lane.project.mcpIssue {
                HStack(alignment: .top, spacing: 10) {
                    Label(issue.kind == .unexpected ? "CLI видит лишний MCP «\(issue.name)»" : "MCP не удалось проверить: \(issue.name)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("MCP проекта…") { store.showPipelineIssues = false; store.selectedProjectID = lane.project.id; store.screen = .project(lane.project.id); store.mcpProjectID = lane.project.id }
                        .buttonStyle(KabanButtonStyle(compact: true))
                }.padding(8).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if store.projection?.ephemeral.schedulerFlags.contains(.mergeBlocked(lane.project.id)) == true {
                MergeBlockNotice(store: store, project: lane.project.id)
            }
            if let pipeline = store.projection?.pipelines[lane.project.id], !pipeline.isValid {
                Label("Пайплайн не запустится: \(pipeline.issues.first(where: { $0.severity == .error })?.message ?? "нужна настройка")", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.status("waiting").2)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 8))
            }
            if displayed.isEmpty {
                Text(store.filter == .hiddenStages ? "Скрытых стадий нет" : "Стадии пока не настроены").font(.system(size: 12)).foregroundStyle(theme.faint).padding(16)
            } else {
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(displayed, id: \.stage.id) { column in
                                columnView(column, project: lane.project, height: laneHeight(lane))
                                    .frame(width: columnWidth(column.stage, project: lane.project.id, all: displayed, available: width - 16))
                            }
                        }.padding(.bottom, 4)
                    }
                }.scrollIndicators(.automatic)
            }
        }.padding(8).frame(width: width, alignment: .leading)
            .background(theme.lane, in: RoundedRectangle(cornerRadius: 14))
    }
    private func minimumColumnWidth(_ stage: StageSummary, project: ProjectID) -> CGFloat {
        if isCollapsed(stage, project: project) { return stage.kind == .gate ? 64 : 88 }
        switch stage.kind { case .queue, .terminal: return 136; case .merge: return 148; default: return 178 }
    }
    private func columnWidth(_ stage: StageSummary, project: ProjectID, all: [BoardColumn], available: CGFloat) -> CGFloat {
        let minimums = all.map { minimumColumnWidth($0.stage, project: project) }
        let extra = max(available - minimums.reduce(0, +) - CGFloat(max(all.count - 1, 0)) * 6, 0)
        let maximum: CGFloat = isCollapsed(stage, project: project) ? (stage.kind == .gate ? 88 : 104) : stage.kind == .queue || stage.kind == .terminal ? 200 : 260
        return min(maximum, minimumColumnWidth(stage, project: project) + extra / CGFloat(max(all.count, 1)))
    }
    private func laneHeight(_ lane: BoardLane) -> CGFloat {
        let count = columns(lane).map { $0.taskIds.filter { store.matches($0) }.count }.max() ?? 0
        return min(330, max(180, 60 + CGFloat(count) * 150))
    }
    private func columnView(_ column: BoardColumn, project: ProjectSummary, height: CGFloat) -> some View {
        let ids = column.taskIds.filter { store.matches($0) }
        let folded = isCollapsed(column.stage, project: project.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                stageCollapsed[.init(projectID: project.id, stageID: column.stage.id)] = !folded
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if folded {
                        HStack {
                            Image(systemName: DesignSystem.symbol(column.stage)).foregroundStyle(DesignSystem.stageColor(column.stage, theme: theme))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 8))
                        }
                        Text(column.stage.name).fontWeight(.semibold).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        stageLoadLabel(project: project.id, stage: column.stage.id)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: DesignSystem.symbol(column.stage)).foregroundStyle(DesignSystem.stageColor(column.stage, theme: theme))
                            Text(column.stage.name).fontWeight(.semibold).lineLimit(1)
                            Spacer(minLength: 0)
                            stageLoadLabel(project: project.id, stage: column.stage.id)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }
                    }
                }.font(.system(size: 11)).foregroundStyle(Color(hex: theme.dark ? 0xf2f2f5 : 0x1d1d1f)).frame(maxWidth: .infinity, alignment: .leading).padding(4).frame(minHeight: 28)
            }.buttonStyle(.plain).help((folded ? "Раскрыть: " : "Свернуть: ") + column.stage.name)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
            if folded {
                Text("Задач · \(column.taskIds.count)").font(.system(size: 10)).foregroundStyle(theme.faint).padding(.horizontal, 3)
                Spacer(minLength: 0)
            } else {
                if let model = column.stage.model {
                    Label(model.rawValue, systemImage: "cpu").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1).padding(.horizontal, 3)
                }
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        if ids.isEmpty {
                            Text(column.taskIds.isEmpty ? "Пусто" : "Нет совпадений").font(.system(size: 11)).foregroundStyle(theme.faint)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.strongLine, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
                        }
                        ForEach(ids, id: \.self) { id in
                            if let card = store.projection?.tasks[id] { taskButton(card, project: project) }
                        }
                    }.padding(.bottom, 4)
                }.scrollIndicators(.automatic)
            }
        }.padding(6).frame(height: height, alignment: .topLeading)
            .background(theme.column, in: RoundedRectangle(cornerRadius: 10))
            .modifier(TaskDropTarget(store: store, project: project.id, stage: column.stage.id))
    }
    @ViewBuilder private func stageLoadLabel(project: ProjectID, stage: StageID) -> some View {
        if let load = store.projection?.load(projectId: project, stageId: stage) {
            let presentation = StageLoadPresentation(load: load)
            Text(presentation.label).monospacedDigit().padding(.horizontal, 4)
                .foregroundStyle(presentation.exceeded ? theme.status("waiting").2 : Color(hex: theme.dark ? 0xb0b2b9 : 0x5f6168))
                .background(presentation.exceeded ? theme.status("waiting").1 : theme.control, in: Capsule())
                .help(presentation.exceeded ? "WIP превышен. Текущие задачи продолжаются." : "Загрузка WIP из службы Kaban")
        }
    }
    private func taskButton(_ card: TaskCard, project: ProjectSummary, stageChip: String? = nil) -> some View {
            TaskCardView(card: card, mascot: store.mascot(project.id), selected: store.selectedID == card.id, pendingLabel: store.pendingLabel(.task(card.id)), pipeline: store.projection?.pipelines[project.id], progress: store.progress(for: card), actualModel: store.currentRun(for: card)?.actualModelName, stageChip: stageChip,
                         queuePosition: MergePresentation.position(card.id, queue: store.mergeQueue(card.projectId)),
                         select: { Task { await store.select(card.id) } }, overlaps: { store.overlapRoute = .init(task: card.id) })
            .modifier(TaskDragSource(store: store, card: card))
            .task(id: BoardCardReadKey(card: card, generation: store.session.sessionGeneration)) { await store.readRunFacts(for: card) }
            .contextMenu {
                Button("Открыть детали") { Task { await store.select(card.id) } }
                if TaskActions.canEdit(card) {
                    Button("Изменить…") {
                        store.editorError = nil
                        Task {
                            await store.select(card.id)
                            if let detail = store.detail, detail.task.id == card.id, TaskActions.canEdit(detail.task) { store.sheet = .edit(detail.task, detail.body) }
                        }
                    }.disabled(!store.can(.editTask) || store.session.detailReadState != .loaded).help(store.unavailableReason(.editTask))
                }
                if TaskActions.canSetPriority(card) {
                    Button("Приоритет · \(card.priority)…") { store.editorError = nil; store.sheet = .priority(card) }
                        .disabled(!store.can(.setPriority) || (store.projection?.isSent(card.id) ?? false))
                }
                TaskControlMenu(store: store, card: card)
            }
    }
    private func stagesBoard(width: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(BoardKindGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 6) {
                                ForEach(compactCards(in: group)) { item in
                                    taskButton(item.card, project: item.project, stageChip: item.stageName)
                                }
                            }.padding(.bottom, 4)
                        }
                    }.padding(8).frame(width: 232, height: 560, alignment: .topLeading)
                        .background(theme.lane, in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(.bottom, 4)
        }.frame(width: width)
    }
    private struct CompactCard: Identifiable {
        let card: TaskCard
        let project: ProjectSummary
        let stageName: String
        var id: TaskID { card.id }
    }
    private func compactCards(in group: BoardKindGroup) -> [CompactCard] {
        var result: [CompactCard] = []
        for lane in lanes {
            for column in columns(lane) {
                for id in column.taskIds {
                    guard store.matches(id), let card = store.projection?.tasks[id] else { continue }
                    guard BoardKindGroup.group(card: card, stage: column.stage) == group else { continue }
                    result.append(.init(card: card, project: lane.project, stageName: lane.project.name + " · " + column.stage.name))
                }
            }
        }
        return result
    }
    private var macCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Этот Мак", systemImage: "cpu").font(.system(size: 12, weight: .semibold)); Spacer(); KabanIconButton(symbol: "slider.horizontal.3", help: "Квота и агенты") { store.screen = .quota } }
            Button { Task { await store.toggleMacPause() } } label: {
                Label(store.macPaused ? "Продолжить новые запуски" : "Пауза новых запусков", systemImage: store.macPaused ? "play" : "pause")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(KabanButtonStyle())
                .disabled(!store.can(store.macPaused ? .resumeAll : .pauseAll) || store.session.pending(in: .global) != nil)
                .help("Текущие запуски продолжатся. Для остановки одной задачи используйте её паузу.")
            if let label = store.pendingLabel(.global) { Text(label).font(.caption).foregroundStyle(theme.faint) }
            HStack { Text("Процессы агентов").fixedSize(horizontal: false, vertical: true); Spacer(); Text("Нет данных").foregroundStyle(theme.faint).fixedSize() }.font(.system(size: 11))
                .help("Служба пока не сообщает подтверждённые процессы и их потолок.")
            HStack { Text("Резервирования"); Spacer(); Text("\(store.reservationCount)").monospacedDigit() }.font(.system(size: 10)).foregroundStyle(theme.secondary)
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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Расход по пулам моделей").font(.system(size: 13)).foregroundStyle(theme.secondary)
                        quotaRows.padding(18).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
                        Text("Данные квоты появятся после подключения источника состояния.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                    }.frame(width: 200)
                    ModelSettingsView(store: store.models, theme: theme).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: 1100, alignment: .leading).padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct BoardCardReadKey: Hashable {
    let card: TaskCard
    let generation: UUID
}
struct TaskCardView: View {
    let card: TaskCard
    var mascot: MascotPick = MascotKit.pick(seed: "kaban")
    let selected: Bool
    let pendingLabel: String?
    var pipeline: PipelineSummary? = nil
    var progress: RunProgress? = nil
    var actualModel: String? = nil
    var stageChip: String? = nil
    var queuePosition: Int? = nil
    var select: (() -> Void)? = nil
    var overlaps: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || BoardQA.argument("--qa-reduce-motion") == "yes" }
    @State private var visible = false
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var presentation: CardPresentation {
        .init(card: card, stage: pipeline?.stages.first { $0.id == card.stageId }, hasCurrentProgress: progress != nil)
    }
    private var badges: [CardBadge] { CardPresentation.badges(card: card, pipeline: pipeline).filter { $0.symbol != "square.on.square" } }
    var body: some View {
        let colors = theme.status(presentation.tone.rawValue)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(mascot.emoji).font(.system(size: 11))
                    Text(card.id.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if card.priority > 0 { Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.faint).help("Повышенный приоритет") }
                }
                Text(card.title).font(.system(size: 12, weight: .medium)).lineSpacing(1).lineLimit(2)
                    .strikethrough(card.state == .cancelled).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(card.state == .done || card.state == .cancelled ? theme.secondary : theme.text)
                    .help(card.title)
                if let stageChip {
                    Text(stageChip).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(1).help(stageChip)
                }
                if let queuePosition { Text("Очередь · \(queuePosition)").font(.system(size: 10)).foregroundStyle(theme.secondary).monospacedDigit() }
                if !card.overlapsWith.isEmpty {
                    Button { overlaps?() } label: { Label("Пересечения · \(card.overlapsWith.count)", systemImage: "square.on.square").font(.system(size: 9.5)).lineLimit(1) }
                        .buttonStyle(.plain).foregroundStyle(theme.secondary).padding(.horizontal, 4).padding(.vertical, 2)
                        .background(theme.control, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier("task.overlaps." + card.id.rawValue)
                }
                if !badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(badges.prefix(2).enumerated()), id: \.offset) { _, badge in
                            Label(badge.label, systemImage: badge.symbol).font(.system(size: 9.5)).lineLimit(1)
                                .padding(.horizontal, 4).padding(.vertical, 2).background(theme.control, in: RoundedRectangle(cornerRadius: 4)).help(badge.help)
                        }
                        if badges.count > 2 {
                            Text("+\(badges.count - 2)").font(.system(size: 9.5)).foregroundStyle(theme.secondary)
                                .help(badges.dropFirst(2).map(\.help).joined(separator: "\n"))
                        }
                    }
                }
                ForEach(Array(card.suspiciousFiles.prefix(2)), id: \.path) { file in
                    Text(file.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(colors.2).lineLimit(1).truncationMode(.middle).help(file.path)
                }
                if card.suspiciousFiles.count > 2 { Text("+\(card.suspiciousFiles.count - 2) файла").font(.system(size: 10)).foregroundStyle(colors.2) }
                if card.state == .waitingHuman(.modelSubstituted), let actualModel {
                    Text("\(card.model?.rawValue ?? "Запрошенная модель неизвестна") → \(actualModel)")
                        .font(.system(size: 10)).foregroundStyle(colors.2).lineLimit(2)
                }
                if let message = progress?.message, !message.isEmpty {
                    Text(message).font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(2).help(message)
                }
                if CardPresentation.retryCountdown(card: card, now: .now) != nil {
                    if visible && !reduceMotion {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(CardPresentation.retryCountdown(card: card, now: context.date) ?? "")
                                .font(.system(size: 10)).foregroundStyle(theme.status("retry").2).monospacedDigit()
                        }
                    } else {
                        if let retryAt = card.retryAt {
                            Text("Повтор после " + retryAt.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10)).foregroundStyle(theme.status("retry").2).monospacedDigit()
                        }
                    }
                }
            }.padding(.init(top: 8, leading: 11, bottom: 8, trailing: 8))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: pendingLabel != nil ? "paperplane" : presentation.symbol).font(.system(size: 10))
                Text(pendingLabel ?? presentation.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if case .waitingHuman(.runLimit) = card.state, let pipeline {
                    Text("\(card.runsSinceHuman) из \(pipeline.maxRunsPerTask)").font(.system(size: 10)).monospacedDigit().fixedSize()
                } else if let qualifier = LimitReasonText(card: card, pipeline: pipeline).qualifier {
                    Text(qualifier).font(.system(size: 10)).monospacedDigit().lineLimit(2)
                } else if card.attempt > 0 {
                    Text(card.maxAttempts.map { "\(card.attempt)/\($0)" } ?? "\(card.attempt)").font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.faint).fixedSize().help("Попытки в текущей стадии")
                }
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
        .onTapGesture { select?() }
        .focusable(select != nil)
        .onKeyPress(.return) { guard let select else { return .ignored }; select(); return .handled }
        .onKeyPress(.space) { guard let select else { return .ignored }; select(); return .handled }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }.onDisappear { visible = false }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select?() }
        .accessibilityLabel("\(card.id.rawValue), \(card.title), \(stageChip.map { $0 + ", " } ?? "")\(presentation.label), \(badges.map(\.help).joined(separator: ", "))\(pendingLabel.map { ", " + $0 } ?? "")")
    }
}

struct MascotPickerView: View {
    @Bindable var store: BoardStore
    let projectID: ProjectID
    @State private var selection: Int?
    @State private var texture: EdgeTexture?
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var current: MascotPick { store.mascot(projectID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Маскот проекта").font(.system(size: 16, weight: .semibold))
            Text(store.projection?.projects[projectID]?.name ?? "").font(.system(size: 12)).foregroundStyle(theme.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 6), spacing: 8) {
                ForEach(MascotKit.mascots.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        Text(MascotKit.mascots[index]).font(.system(size: 24)).frame(width: 38, height: 38)
                            .background((selection ?? current.mascotIndex) == index ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke((selection ?? current.mascotIndex) == index ? theme.accent : .clear))
                    }.buttonStyle(.plain).accessibilityLabel("Маскот \(MascotKit.mascots[index])")
                }
            }
            Text("Фактура края").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(EdgeTexture.allCases, id: \.self) { value in
                    Button { texture = value } label: {
                        ProjectEdgeTexture(texture: value, color: theme.text).frame(width: 12, height: 28).padding(7)
                            .background((texture ?? current.texture) == value ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help(value.key).accessibilityLabel(value.key)
                }
            }
            if let pending = store.pendingLabel(.project(projectID)) { Text(pending).font(.system(size: 11)).foregroundStyle(theme.secondary) }
            HStack {
                Button("Закрыть") { store.mascotProjectID = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить") { Task { await store.setMascot(projectID, index: selection ?? current.mascotIndex, texture: texture ?? current.texture) } }
                    .buttonStyle(KabanButtonStyle(primary: true))
                    .disabled(!store.session.can(.setMascot(projectId: projectID, seed: "")))
            }
        }.padding(18).frame(width: 320).background(theme.window).foregroundStyle(theme.text)
    }
}

struct ProjectEdgeTexture: View {
    let texture: EdgeTexture
    let color: Color
    var body: some View {
        Canvas { context, size in
            for y in stride(from: 0.0, to: size.height + 8, by: 8) {
                var path = Path()
                switch texture {
                case .dots:
                    context.fill(Path(ellipseIn: .init(x: max((size.width - 2) / 2, 0), y: y, width: 2, height: 2)), with: .color(color))
                case .solidThin:
                    context.fill(Path(CGRect(x: 0, y: y, width: min(size.width, 2), height: 8)), with: .color(color.opacity(0.65)))
                case .grid:
                    path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y))
                    path.move(to: .init(x: size.width / 2, y: y)); path.addLine(to: .init(x: size.width / 2, y: y + 8))
                case .crosshatch:
                    path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y + 8))
                    path.move(to: .init(x: size.width, y: y)); path.addLine(to: .init(x: 0, y: y + 8))
                case .waves:
                    path.move(to: .init(x: 0, y: y)); path.addQuadCurve(to: .init(x: size.width, y: y + 4), control: .init(x: 0, y: y + 4))
                    path.addQuadCurve(to: .init(x: 0, y: y + 8), control: .init(x: size.width, y: y + 8))
                case .zigzag:
                    path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y + 4)); path.addLine(to: .init(x: 0, y: y + 8))
                case .chevrons:
                    path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width / 2, y: y + 4)); path.addLine(to: .init(x: size.width, y: y))
                case .stripes:
                    path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y + 4))
                }
                context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 0.8)
            }
        }.accessibilityHidden(true)
    }
}

struct TaskDetailView: View {
    @Bindable var store: BoardStore
    let openSheet: (TaskSheetRoute) -> Void
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var tab: String { store.detailTab }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let card = store.selectedID.flatMap({ store.projection?.tasks[$0] }) {
                detailHeader(card)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        readStatus
                        if card.state != .waitingHuman(.modelSubstituted), (card.state != .waitingHuman(.review) || store.projection?.pipelines[card.projectId]?.stages.first(where: { $0.id == card.stageId })?.kind != .human),
                           store.projection?.pipelines[card.projectId]?.stages.first(where: { $0.id == card.stageId })?.kind != .merge {
                            HumanAnswerView(store: store, card: card)
                        }
                        HumanReviewNotice(store: store, taskID: card.id)
                        if let error = store.cloneOpeningError { Text(error).font(.caption).foregroundStyle(theme.secondary) }
                        if let detail = store.detail {
                            MergeProgressView(store: store, detail: detail)
                            TaskModelView(store: store, detail: detail, theme: theme)
                            if !card.suspiciousFiles.isEmpty { suspiciousBlock(card.suspiciousFiles) }
                            if detail.task.state == .waitingHuman(.incident) {
                                Label("Обнаружен инцидент", systemImage: "light.beacon.max")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.status("incident").2)
                            }
                            if tab == "Описание" { description(detail) }
                            else if tab == "Лента" { feed(detail) }
                            else if tab == "Сводка" { summary(detail) }
                        }
                        if tab == "Запуски" { runs(availableRuns) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.task(id: store.detail?.task.id) {
                    if let source = BoardQA.argument("--qa-review-artifact") {
                        try? await Task.sleep(for: .milliseconds(350))
                        proxy.scrollTo(source, anchor: .top)
                    }
                }
                }
                if let detail = store.detail { detailActions(detail).padding(12).background(theme.window) }
            } else {
                HStack { Text("Задача").font(.headline); Spacer(); closeButton }.padding(16)
                Text("Задача больше недоступна").foregroundStyle(theme.secondary).padding(16)
                Spacer()
            }
        }.background(theme.dark ? Color(hex: 0x242429) : Color(hex: 0xfcfcfe))
            .sheet(item: $store.materialTextRoute) { MaterialTextSheet(route: $0) }
            .sheet(item: $store.logRunRoute) { run in RunLogSheet(store: store, run: run) }
            .sheet(item: $store.wipRestoreRoute) { route in WIPRestoreSheet(store: store, route: route) }
            .sheet(item: $store.modelOverrideRoute) { editor in TaskModelOverrideSheet(store: store, editor: editor) }
            .onChange(of: store.selectedID) { _, id in store.detailTab = id.flatMap { store.projection?.tasks[$0] }?.state == .waitingHuman(.review) ? "Сводка" : "Описание"; store.materialTextRoute = nil; store.logRunRoute = nil }
    }
    private var availableRuns: [RunSummary]? {
        if case .unavailable = store.session.detailReadState { return store.session.runHistory ?? store.detail?.runs }
        return store.detail?.runs ?? store.session.runHistory
    }
    @ViewBuilder private var readStatus: some View {
        switch store.session.detailReadState {
        case .idle: Text("Выберите задачу").foregroundStyle(theme.secondary)
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(store.detail == nil ? "Загрузка деталей…" : "Обновление деталей…").font(.system(size: 12)) }
        case .loaded: EmptyView()
        case .unavailable(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.code == CommandError.detailTooLargeCode ? "Детали слишком большие" : "Детали недоступны", systemImage: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(failure.message).font(.system(size: 12)).textSelection(.enabled)
                if failure.code == CommandError.detailTooLargeCode {
                    Text("Описание и материалы сохранены в службе целиком. Историю запусков и страницы логов можно читать отдельно.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary)
                    if let bytes = failure.params["bytes"], let limit = failure.params["limit"] {
                        Text("\(bytes) байт · предел ответа \(limit) байт").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint)
                    }
                }
                if store.detail != nil { Text("Ниже — последние загруженные данные.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                HStack {
                    Button("Повторить чтение") { Task { await store.session.retryDetail() } }.buttonStyle(KabanButtonStyle(compact: true))
                    Button("История запусков") { store.detailTab = "Запуски"; Task { await store.session.readRunHistory() } }.buttonStyle(KabanButtonStyle(compact: true))
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.control, in: RoundedRectangle(cornerRadius: 9))
        }
    }
    private var closeButton: some View { KabanIconButton(symbol: "xmark", help: "Закрыть детали · Esc") { Task { await store.select(nil) } } }
    private func detailHeader(_ task: TaskCard) -> some View {
        let presentation = CardPresentation(card: task, stage: store.projection?.pipelines[task.projectId]?.stages.first { $0.id == task.stageId })
        let stages: [StageSummary] = (store.projection?.pipelines[task.projectId]?.stages ?? []).sorted { $0.display.order < $1.display.order }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text(store.mascot(task.projectId).emoji)
                Text(task.id.rawValue).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle).help(task.id.rawValue)
                Text(store.projection?.projects[task.projectId]?.name ?? "").font(.system(size: 11)).foregroundStyle(theme.faint).lineLimit(1)
                Spacer(); closeButton
            }
            Text(task.title).font(.system(size: 18, weight: .bold)).lineLimit(3).fixedSize(horizontal: false, vertical: true).help(task.title)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { status(presentation); attempt(task); if let model = task.model { ReferenceChip(title: model.rawValue, theme: theme, mono: true) } }
                VStack(alignment: .leading, spacing: 5) { status(presentation); HStack { attempt(task); if let model = task.model { Text(model.rawValue).font(.system(size: 10, design: .monospaced)).lineLimit(1).help(model.rawValue) } } }
            }
            if let branch = task.branch { Label(branch, systemImage: "arrow.triangle.branch").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(branch) }
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(stages, id: \.id) { stage in
                        Text(stage.name).font(.system(size: 10, weight: stage.id == task.stageId ? .semibold : .regular))
                            .foregroundStyle(stage.id == task.stageId ? theme.text : theme.faint)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(stage.id == task.stageId ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }.scrollIndicators(.hidden)
            KabanSegments(selection: $store.detailTab, options: [("Описание", "Описание"), ("Лента", "Лента"), ("Сводка", "Сводка"), ("Запуски", "Запуски")])
        }.padding(16).overlay(alignment: .bottom) { theme.line.frame(height: 0.5) }
    }
    private func status(_ value: CardPresentation) -> some View {
        Label(value.label, systemImage: value.symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.status(value.tone.rawValue).2).padding(.horizontal, 8).padding(.vertical, 4)
            .background(theme.status(value.tone.rawValue).1, in: RoundedRectangle(cornerRadius: 6))
    }
    @ViewBuilder private func attempt(_ task: TaskCard) -> some View {
        if task.attempt > 0 || store.projection?.pipelines[task.projectId]?.stages.first(where: { $0.id == task.stageId })?.kind == .agent {
            Text(task.maxAttempts.map { "попытка \(task.attempt) из \($0)" } ?? "попытка \(task.attempt) · лимит неизвестен")
                .font(.system(size: 10)).foregroundStyle(theme.secondary)
        }
    }
    @ViewBuilder private func description(_ detail: TaskDetail) -> some View {
        Text("Описание и критерии приёмки").font(.system(size: 12, weight: .semibold))
        if let body = detail.body {
            if body.isEmpty { empty("Описание пока пустое") }
            else if body.utf8.count > TaskDetailPresentation.largeTextBytes {
                Text("Большое описание · полный исходный текст доступен отдельно.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Button("Открыть описание целиком…") { store.materialTextRoute = .init(id: "body-" + detail.task.id.rawValue, title: "Описание и критерии приёмки", text: body) }.buttonStyle(KabanButtonStyle(compact: true))
            } else { TaskMarkdownView(source: body) }
        } else { empty("Служба не передала описание") }
        if !detail.humanRequests.isEmpty {
            Divider()
            Text("Вопросы").font(.system(size: 12, weight: .semibold))
            ForEach(detail.humanRequests, id: \.requestId) { request in
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.question).font(.system(size: 12)).textSelection(.enabled)
                    runLink(request.runId, detail: detail)
                }
            }
            Text("Ответы сохранены в ленте задачи.").font(.system(size: 11)).foregroundStyle(theme.secondary)
        }
    }
    @ViewBuilder private func feed(_ detail: TaskDetail) -> some View {
        if detail.feed.isEmpty { empty("Событий пока нет") }
        ForEach(detail.feed, id: \.id) { item in
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TaskDetailPresentation.feedTitle(item.kind)).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(detailDate(item.at)).font(.system(size: 10)).foregroundStyle(theme.faint)
                }
                Text(item.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                runLink(item.runId, detail: detail)
            }.padding(.vertical, 6)
            Divider()
        }
    }
    private func summary(_ detail: TaskDetail) -> some View {
        ReviewMaterialsView(store: store, detail: detail)
    }
    @ViewBuilder private func runs(_ values: [RunSummary]?) -> some View {
        HStack {
            Text("История запусков").font(.system(size: 12, weight: .semibold)); Spacer()
            Button("Обновить") { Task { await store.session.readRunHistory() } }.buttonStyle(KabanButtonStyle(compact: true))
                .disabled(store.session.historyReadState == .loading)
        }
        if let id = store.selectedID, let record = store.restoreRecord(for: id) {
            Text(restoreStatus(record.phase)).font(.system(size: 11)).foregroundStyle(theme.secondary)
                .textSelection(.enabled)
                .task(id: record.phase) {
                    if record.phase == .applied { await store.session.retryDetail(); await store.session.readRunHistory() }
                }
        }
        if store.session.historyReadState == .loading { ProgressView("Читаем историю…").controlSize(.small) }
        if case .unavailable(let failure) = store.session.historyReadState { Text(failure.message).font(.system(size: 12)).foregroundStyle(theme.secondary) }
        if let id = store.selectedID, let card = store.projection?.tasks[id] {
            Text("Попытка в текущем заходе в стадию: \(card.attempt) / \(card.maxAttempts.map(String.init) ?? "лимит неизвестен")")
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
        }
        if let values {
            if values.isEmpty { empty("Запусков пока нет") }
            ForEach(Array(values.reversed()), id: \.id) { run in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(stageName(run.stageId, detail: store.detail)) · запуск №\(run.number)").font(.system(size: 12, weight: .semibold))
                        Spacer(); Text(runStatus(run.status)).font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }
                    HStack {
                        Button("Читать лог…") { store.logRunRoute = run }.buttonStyle(KabanButtonStyle(compact: true))
                        if run.wipRef != nil, let card = store.projection?.tasks[run.taskId],
                           WIPRestoreRequest(card: card, run: run, pipeline: store.projection?.pipelines[card.projectId]).isAvailable {
                            Button("Восстановить WIP…") { store.beginWIPRestore(run) }.buttonStyle(KabanButtonStyle(compact: true))
                                .disabled(!store.can(.restoreWIP) || store.session.pending(in: .task(card.id)) != nil)
                                .help(store.unavailableReason(.restoreWIP))
                        }
                    }
                    Text("Запрошена: \(run.requestedModel.rawValue)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2).help(run.requestedModel.rawValue)
                    Text(run.actualModelName.map { "Фактическая модель: " + $0 } ?? "Фактическая модель не подтверждена").font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(2).help(run.actualModelName ?? "Фактическая модель не подтверждена")
                    Text(run.countsTowardLimits ? "Учитывается в лимите попыток" : "Не учитывается в лимите попыток").font(.system(size: 10)).foregroundStyle(theme.secondary)
                    if let reason = run.endReason { Text("Причина завершения: " + runEndReason(reason)).font(.system(size: 11)).foregroundStyle(theme.secondary) }
                    DisclosureGroup("Время, WIP и сведения запуска") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Начало: " + detailDate(run.startedAt))
                            Text(run.endedAt.map { "Завершение: " + detailDate($0) } ?? "Завершение не подтверждено")
                            if let end = run.endedAt, end >= run.startedAt { Text("Длительность: \(Int(end.timeIntervalSince(run.startedAt))) с") }
                            Text(run.stageId == store.projection?.tasks[run.taskId]?.stageId ? "Стадия текущей задачи" : "Предыдущая стадия")
                            Text("Номер попытки в заходе не передан")
                            if let exit = run.exitCode { Text("Код завершения: \(exit)") }
                            if let ref = run.wipRef {
                                Text("WIP: " + ref).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    .lineLimit(3).truncationMode(.middle).help(ref)
                                    .contextMenu { Button("Скопировать WIP") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref, forType: .string) } }
                            } else { Text("WIP не передан") }
                            if let path = run.logPath { Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(path) }
                            Button("Все сведения целиком…") {
                                let encoder = KabanCoding.makeEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                if let data = try? encoder.encode(run) {
                                    store.materialTextRoute = .init(id: "run:" + run.id.rawValue, title: "Сведения запуска №\(run.number)", text: String(decoding: data, as: UTF8.self))
                                }
                            }.buttonStyle(.link)
                        }.font(.system(size: 10)).foregroundStyle(theme.faint).padding(.top, 5)
                    }.font(.system(size: 11)).foregroundStyle(theme.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 9))
            }
        } else { empty("История ещё не загружена"); Button("Загрузить историю") { Task { await store.session.readRunHistory() } }.buttonStyle(KabanButtonStyle(compact: true)) }
    }
    private func restoreStatus(_ phase: ClientCommandPhase) -> String {
        switch phase {
        case .sending: "Отправляем восстановление WIP…"
        case .deliveryUncertain: "Проверяем исход отправки восстановления…"
        case .awaitingEvent, .awaitingEffect: "Служба восстанавливает WIP. Ожидаем подтверждение."
        case .applied: "Восстановление WIP подтверждено службой."
        case .rejected(let error), .effectFailed(let error): "WIP не восстановлен: " + error.message
        case .superseded: "Восстановление WIP отменено более поздним действием."
        }
    }
    @ViewBuilder private func runLink(_ id: RunID?, detail: TaskDetail) -> some View {
        if let id {
            if let run = detail.runs.first(where: { $0.id == id }) { Button("Лог · запуск №\(run.number)") { store.logRunRoute = run }.font(.system(size: 11)).buttonStyle(.link) }
            else { Text("Запуск: " + id.rawValue + " · сведения ещё недоступны").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).textSelection(.enabled) }
        }
    }
    private func detailDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "ru_RU")
        format.timeZone = .current
        format.dateFormat = "d MMM yyyy, HH:mm"
        return format.string(from: date)
    }
    private func runEndReason(_ reason: RunEndReason) -> String {
        switch reason {
        case .crash: "сбой процесса"
        case .stallTimeout: "нет активности"
        case .wallTimeout: "истекло время запуска"
        case .noFinalCall: "нет завершающего вызова"
        case .gateFailed: "проверка не пройдена"
        case .rateLimit: "лимит запросов"
        case .runnerAuth: "нужна авторизация"
        case .daemonRestart: "служба перезапущена"
        case .silentExit: "процесс завершился без результата"
        case .modelSubstituted: "модель заменена"
        case .readonlyViolation: "нарушен режим чтения"
        case .completed: "стадия завершена"
        case .returned: "возврат на стадию"
        case .askedHuman: "вопрос человеку"
        case .pausedByHuman: "пауза пользователем"
        case .movedByHuman: "перенос пользователем"
        }
    }
    private func runStatus(_ status: RunStatus) -> String {
        switch status {
        case .starting: "Подготовка"
        case .running: "Зарезервирован"
        case .succeeded: "Завершён"
        case .failed: "Ошибка"
        case .killed: "Остановлен"
        }
    }
    private func stageName(_ id: StageID, detail: TaskDetail?) -> String {
        let project = detail?.task.projectId ?? store.selectedID.flatMap { store.projection?.tasks[$0]?.projectId }
        return project.flatMap { store.projection?.pipelines[$0]?.stages.first { $0.id == id }?.name } ?? id.rawValue
    }
    private func empty(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(theme.faint) }
    private func suspiciousBlock(_ files: [SuspiciousFile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Подозрительные файлы · \(files.count)", systemImage: "exclamationmark.shield")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.status("waiting").2)
            Text("Проверьте файлы перед следующим действием.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            ForEach(files, id: \.path) { file in
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
    @ViewBuilder private func detailActions(_ detail: TaskDetail) -> some View {
        if detail.task.state == .waitingHuman(.review), store.projection?.pipelines[detail.task.projectId]?.stages.first(where: { $0.id == detail.task.stageId })?.kind == .human {
            HumanReviewFooter(store: store, detail: detail,
                edit: { store.editorError = nil; openSheet(.edit(detail.task, detail.body)) },
                priority: { store.editorError = nil; openSheet(.priority(detail.task)) })
        } else {
        VStack(alignment: .leading, spacing: 8) {
            if store.humanAnswers.currentContext(for: detail.task.id)?.card.state == .waitingHuman(.suspiciousFiles) {
                Text("Набор файлов не принимается · агент получит новый запуск")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if detail.task.state != .waitingHuman(.modelSubstituted), store.humanAnswers.draft(for: detail.task.id) != nil {
                    HumanAnswerSubmitButton(store: store, taskID: detail.task.id)
                }
                if TaskActions.canPause(detail.task) {
                    Button { store.beginControl(detail.task, action: .pause) } label: { Label("Пауза", systemImage: "pause") }.buttonStyle(KabanButtonStyle()).disabled(!store.can(.pauseTask)).help(store.unavailableReason(.pauseTask))
                } else if detail.task.state == .paused {
                    Button { store.beginControl(detail.task, action: .resume) } label: { Label("Продолжить", systemImage: "play") }.buttonStyle(KabanButtonStyle(primary: true)).disabled(!store.can(.resumeTask)).help(store.unavailableReason(.resumeTask))
                }
                if !TaskActions.canEdit(detail.task), TaskActions.canPause(detail.task) {
                    Text("Для правки поставьте на паузу").font(.caption).foregroundStyle(.secondary)
                }
                if TaskActions.canEdit(detail.task) {
                    Button("Изменить…") { store.editorError = nil; openSheet(.edit(detail.task, detail.body)) }.buttonStyle(KabanButtonStyle()).disabled(!store.can(.editTask) || store.session.detailReadState != .loaded).help(store.unavailableReason(.editTask))
                }
                Spacer(minLength: 0)
                if TaskActions.canCancel(detail.task) {
                    Menu {
                        Button("Приоритет · \(detail.task.priority)…") { store.editorError = nil; openSheet(.priority(detail.task)) }
                            .disabled(!store.can(.setPriority))
                        TaskControlMenu(store: store, card: detail.task)
                    } label: { Label("Действия", systemImage: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                if store.projection?.isSent(detail.task.id) == true, store.humanAnswers.receipt(for: detail.task.id)?.isPending != true { ProgressView().controlSize(.small) }
            }.disabled(store.projection?.isSent(detail.task.id) ?? false)
        }
        }
    }
}

struct ProjectSettingsView: View {
    @Bindable var store: BoardStore
    let projectID: ProjectID
    let theme: ReferenceTheme
    @State private var selectedStage: StageID?
    @State private var editingPipeline = false
    @State private var pipelineEditor: PipelineEditorStore?
    @State private var metadata: ProjectSettingsStore?
    @State private var mcp: ProjectMCPStore?
    @State private var editorSection: String?
    var body: some View {
        Group {
            if store.mcpProjectID == projectID, let mcp {
                ProjectMCPView(settings: mcp, board: store, theme: theme, close: { store.mcpProjectID = nil }, editStage: { stage in
                    pipelineEditor?.selectedStageID = stage.rawValue; pipelineEditor?.section = "Исполнитель"
                    editorSection = nil; editingPipeline = true; store.mcpProjectID = nil
                })
            } else if editingPipeline, let editor = pipelineEditor, let mcp {
                PipelineEditorView(editor: editor, models: store.models, mcp: mcp,
                    openMCP: { store.mcpProjectID = projectID }, projectName: store.projection?.projects[projectID]?.name ?? projectID.rawValue, theme: theme,
                    close: { editingPipeline = false }, initialSection: editorSection)
                    .onAppear { store.editingPipelineProject = editor.projectID }
                    .onDisappear { if store.editingPipelineProject == editor.projectID { store.editingPipelineProject = nil } }
                    .id(editor.projectID)
            } else { projectSettings }
        }.task(id: projectID) {
            pipelineEditor = store.pipelineEditor(for: projectID)
            metadata = store.settings(for: projectID)
            mcp = store.mcpSettings(for: projectID)
            if store.showPipelineIssues { editingPipeline = true }
        }.onChange(of: store.showPipelineIssues) { _, show in
            if show { editorSection = nil; editingPipeline = true }
        }
    }
    private var projectSettings: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let project = store.projection?.projects[projectID] {
                    HStack(spacing: 12) {
                        ReferenceMascot(emoji: store.mascot(projectID).emoji, theme: theme, state: store.projectStatus(projectID), size: 40)
                        VStack(alignment: .leading, spacing: 4) { Text(project.name).font(.system(size: 22, weight: .bold)); Text(project.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary).textSelection(.enabled) }
                    }
                    HStack {
                        Button("Редактировать пайплайн", systemImage: "slider.horizontal.3") { editorSection = nil; editingPipeline = true }
                            .buttonStyle(KabanButtonStyle(primary: true))
                        Menu(".kaban/ в репозитории") {
                            Button("Права и git") { editorSection = "__git"; editingPipeline = true }
                            Button("Рабочая копия") { editorSection = "__workspace"; editingPipeline = true }
                            Button("Подозрительные файлы") { editorSection = "__files"; editingPipeline = true }
                            Button("Лимиты пайплайна") { editorSection = "__board"; editingPipeline = true }
                        }.menuStyle(.borderlessButton).fixedSize()
                        Button("MCP проекта") { store.mcpProjectID = projectID }.buttonStyle(KabanButtonStyle())
                            .accessibilityIdentifier("project-mcp-open")
                    }
                    if store.showPipelineIssues {
                        settingsSection("Ошибки пайплайна") {
                            if let pipeline = store.projection?.pipelines[projectID] {
                                if pipeline.issues.isEmpty { Text("Служба не передала ошибок текущего пайплайна.").font(.system(size: 12)).foregroundStyle(theme.secondary) }
                                ForEach(Array(pipeline.issues.enumerated()), id: \.offset) { _, issue in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(issue.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                        Text(issue.code + " · " + issue.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondary).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if pipeline.defaultReturnStage == nil { Text("Стадия возврата не передана. Возврат с комментарием недоступен.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                            }
                        }
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
                    if let metadata { ProjectMetadataView(settings: metadata, board: store, theme: theme).id("project-metadata") }
                    if let pipeline = store.projection?.pipelines[projectID] {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Пайплайн").font(.system(size: 13, weight: .semibold))
                            Text("Committed версия. Изменения доступны в редакторе пайплайна.").font(.system(size: 11)).foregroundStyle(theme.secondary)
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
                                GitPolicyView(policy: policy, catalog: pipeline.gitCommandCatalog, theme: theme)
                            } else { settingsRow("Эффективная политика", "Нет данных") }
                        }
                        if let stage = pipeline.stages.first(where: { $0.id == (selectedStage ?? pipeline.stages.first?.id) }), let policy = stage.gitPolicy {
                            settingsSection("Политика стадии · " + stage.name) { GitPolicyView(policy: policy, catalog: pipeline.gitCommandCatalog, theme: theme) }
                        }
                    }
                }
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: metadata?.section) { _, section in
            if section != nil { withAnimation { scroll.scrollTo("project-metadata", anchor: .top) } }
        }
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
