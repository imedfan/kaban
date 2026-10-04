import SwiftUI
import KabanProtocol
import KabanBoardCore

struct BoardView: View {
    @Bindable var store: BoardStore
    var body: some View {
        NavigationSplitView {
            List {
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
                        if store.visibleIDs.isEmpty {
                            ContentUnavailableView("Доска пуста", systemImage: "rectangle.split.3x1", description: Text("Выберите «Показать на доске» в меню проекта."))
                        }
                        ForEach(store.projection?.lanes(orderedBy: store.visibleIDs) ?? [], id: \.project.id) { lane in
                            laneView(lane)
                        }
                    }.padding(16)
                }
                if store.selectedID != nil {
                    Divider()
                    TaskDetailView(store: store).frame(width: 340)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .navigationTitle("Доска")
            .toolbar { ToolbarItem { Label("Демонстрационные данные", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary) } }
        }
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
                Button { store.hide(lane.project.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Убрать с доски")
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
                Text("\(file.path) · \(file.rule == .pattern ? file.pattern ?? "по шаблону" : "больше 5 МБ")")
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
                    if !detail.suspiciousFiles.isEmpty {
                        Divider()
                        Text("Подозрительные файлы").font(.headline)
                        ForEach(detail.suspiciousFiles, id: \.path) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text(file.rule == .pattern ? "по шаблону \(file.pattern ?? "—")" : "больше 5 МБ").font(.caption).foregroundStyle(.secondary)
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
