import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let kabanSpikeTask = UTType(exportedAs: "app.kaban.spike.task-ref")
    static let kabanSpikeProject = UTType(exportedAs: "app.kaban.spike.project-ref")
}

struct TaskDragItem: Codable, Transferable, Equatable {
    var taskID: String
    var projectID: String
    var columnIndex: Int
    var hasAcceptance: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kabanSpikeTask)
    }
}

struct ProjectDragItem: Codable, Transferable, Equatable {
    var projectID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kabanSpikeProject)
    }
}

enum DropVerdict: String {
    case allow
    case allowNeedsConfirm
    case forbidForward
    case forbidOtherProject
    case samePlace
}

enum FS3Rules {
    static func verdict(item: TaskDragItem, projectID: String, columnIndex: Int) -> DropVerdict {
        if item.projectID != projectID { return .forbidOtherProject }
        if item.columnIndex == columnIndex { return .samePlace }
        if columnIndex > item.columnIndex {
            if item.columnIndex == 0 && columnIndex == 1 && item.hasAcceptance {
                return .allow
            }
            return .forbidForward
        }
        return .allowNeedsConfirm
    }
}

@MainActor
@Observable
final class DragSession {
    var task: TaskDragItem?
    var projectID: String?

    func beginTask(_ item: TaskDragItem) {
        task = item
        projectID = nil
    }

    func beginProject(_ id: String) {
        projectID = id
        task = nil
    }

    func clear() {
        task = nil
        projectID = nil
    }
}

struct FS3Project: Identifiable, Equatable {
    var id: String
    var name: String
    var columns: [FS3Column]
}

struct FS3Column: Identifiable, Equatable {
    var id: String
    var title: String
    var index: Int
    var collapsed: Bool
    var isGate: Bool
    var cards: [FS3Card]
}

struct FS3Card: Identifiable, Equatable {
    var id: String
    var title: String
    var hasAcceptance: Bool
}

struct FS3DragView: View {
    @State private var catalog: [FS3Project] = FS3DragView.seed()
    @State private var boardIDs: [String] = ["alpha", "beta"]
    @State private var drag = DragSession()
    @State private var log: [String] = []

    private var board: [FS3Project] {
        boardIDs.compactMap { id in catalog.first { $0.id == id } }
    }

    var body: some View {
        SpikeScreen(
            code: "FS-3",
            title: "Drag Transferable",
            instruments: "Отдельного шаблона нет: смотрите подсветку и журнал. Если drop молчит, проверьте UTType в собранном Info.plist."
        ) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                boardColumn
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Проекты")
                .font(.headline)
                .padding(8)
            List(catalog) { project in
                HStack {
                    Text(project.name)
                    Spacer()
                    if boardIDs.contains(project.id) {
                        Image(systemName: "rectangle.split.3x1")
                            .foregroundStyle(.secondary)
                    }
                }
                .draggable(ProjectDragItem(projectID: project.id)) {
                    Text(project.name)
                        .padding(6)
                        .onAppear { drag.beginProject(project.id) }
                        .onDisappear { drag.clear() }
                }
                .contextMenu {
                    Button("Показать на доске") { showOnBoard(project.id, at: boardIDs.count) }
                    Button("Скрыть с доски") { hide(project.id) }
                }
            }
            Text("Запасной путь: меню «Показать на доске» и «Переместить в».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var boardColumn: some View {
        VStack(spacing: 0) {
            if board.isEmpty {
                emptyBoard
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        dropZone(index: 0)
                        ForEach(Array(board.enumerated()), id: \.element.id) { offset, project in
                            Section {
                                projectBody(project)
                            } header: {
                                projectHeader(project)
                            }
                            dropZone(index: offset + 1)
                        }
                    }
                }
            }
            LogList(lines: log)
                .frame(height: 120)
        }
    }

    private var emptyBoard: some View {
        Text("Перетащите проект сюда")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor.windowBackgroundColor))
            .dropDestination(for: ProjectDragItem.self) { items, _ in
                guard let item = items.first else { return false }
                showOnBoard(item.projectID, at: 0)
                drag.clear()
                return true
            }
    }

    private func dropZone(index: Int) -> some View {
        let active = drag.projectID != nil
        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 18)
            if active {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .dropDestination(for: ProjectDragItem.self) { items, _ in
            guard let item = items.first else { return false }
            showOnBoard(item.projectID, at: index)
            drag.clear()
            return true
        }
    }

    private func projectHeader(_ project: FS3Project) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal")
            Text(project.name).font(.headline)
            Spacer()
            Button("Убрать с доски") { hide(project.id) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .draggable(ProjectDragItem(projectID: project.id)) {
            Text(project.name)
                .padding(6)
                .onAppear { drag.beginProject(project.id) }
                .onDisappear { drag.clear() }
        }
    }

    private func projectBody(_ project: FS3Project) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(project.columns) { column in
                columnView(project: project, column: column)
            }
        }
        .padding(12)
    }

    private func columnView(project: FS3Project, column: FS3Column) -> some View {
        let tint = highlight(project: project, column: column)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(column.isGate ? "ворота" : column.title)
                    .font(.caption.bold())
                Spacer()
                if !column.isGate {
                    Button(column.collapsed ? "▸" : "▾") {
                        toggleCollapsed(project: project.id, column: column.id)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if column.isGate {
                Text("\(column.cards.count)")
                    .font(.title3.monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else if column.collapsed {
                Text("свёрнут")
                    .font(.caption2)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(column.cards) { card in
                    cardView(project: project, column: column, card: card)
                }
            }
        }
        .padding(8)
        .frame(width: column.isGate ? 88 : (column.collapsed ? 72 : 160), alignment: .top)
        .background(tint.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint, lineWidth: 2))
        .dropDestination(for: TaskDragItem.self) { items, _ in
            guard let item = items.first else { return false }
            let accepted = receive(item, project: project, column: column)
            drag.clear()
            return accepted
        }
    }

    private func cardView(project: FS3Project, column: FS3Column, card: FS3Card) -> some View {
        let item = TaskDragItem(
            taskID: card.id,
            projectID: project.id,
            columnIndex: column.index,
            hasAcceptance: card.hasAcceptance
        )
        return VStack(alignment: .leading, spacing: 2) {
            Text(card.title).font(.caption)
            Text(card.hasAcceptance ? "критерии есть" : "без критериев")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .draggable(item) {
            Text(card.title)
                .padding(6)
                .onAppear { drag.beginTask(item) }
                .onDisappear { drag.clear() }
        }
        .contextMenu {
            Menu("Переместить в") {
                ForEach(project.columns) { target in
                    Button(target.title) {
                        _ = receive(item, project: project, column: target)
                    }
                }
            }
        }
    }

    private func highlight(project: FS3Project, column: FS3Column) -> Color {
        guard let item = drag.task else { return .clear }
        switch verdict(item, project: project, column: column) {
        case .allow: return .green
        case .allowNeedsConfirm: return .orange
        case .forbidForward, .forbidOtherProject: return .red
        case .samePlace: return .gray
        }
    }

    /// Ворота в этом спайке — отдельная цель: drop на полоску проверяем даже с более ранней стадии.
    private func verdict(_ item: TaskDragItem, project: FS3Project, column: FS3Column) -> DropVerdict {
        if column.isGate {
            return item.projectID == project.id ? .allow : .forbidOtherProject
        }
        return FS3Rules.verdict(item: item, projectID: project.id, columnIndex: column.index)
    }

    private func receive(_ item: TaskDragItem, project: FS3Project, column: FS3Column) -> Bool {
        let verdict = verdict(item, project: project, column: column)
        switch verdict {
        case .forbidForward, .forbidOtherProject, .samePlace:
            record("отказ \(item.taskID) → \(project.id)/\(column.title): \(verdict.rawValue)")
            return false
        case .allow, .allowNeedsConfirm:
            move(item, to: project.id, column: column)
            if column.collapsed {
                toggleCollapsed(project: project.id, column: column.id)
                record("drop на свёрнутый \(column.title), развернули")
            }
            if column.isGate {
                record("drop на GateStrip \(item.taskID)")
            } else {
                record("\(verdict.rawValue) \(item.taskID) → \(project.id)/\(column.title)")
            }
            return true
        }
    }

    private func move(_ item: TaskDragItem, to projectID: String, column: FS3Column) {
        guard let sourceProject = catalog.firstIndex(where: { $0.id == item.projectID }),
              let sourceColumn = catalog[sourceProject].columns.firstIndex(where: { $0.cards.contains { $0.id == item.taskID } }),
              let cardIndex = catalog[sourceProject].columns[sourceColumn].cards.firstIndex(where: { $0.id == item.taskID }),
              let targetProject = catalog.firstIndex(where: { $0.id == projectID }),
              let targetColumn = catalog[targetProject].columns.firstIndex(where: { $0.id == column.id })
        else { return }
        let card = catalog[sourceProject].columns[sourceColumn].cards.remove(at: cardIndex)
        catalog[targetProject].columns[targetColumn].cards.append(card)
    }

    private func toggleCollapsed(project: String, column: String) {
        guard let projectIndex = catalog.firstIndex(where: { $0.id == project }),
              let columnIndex = catalog[projectIndex].columns.firstIndex(where: { $0.id == column })
        else { return }
        catalog[projectIndex].columns[columnIndex].collapsed.toggle()
    }

    private func showOnBoard(_ id: String, at index: Int) {
        boardIDs.removeAll { $0 == id }
        let clamped = min(max(0, index), boardIDs.count)
        boardIDs.insert(id, at: clamped)
        record("доска: \(boardIDs.joined(separator: ", "))")
    }

    private func hide(_ id: String) {
        boardIDs.removeAll { $0 == id }
        record("скрыт \(id)")
    }

    private func record(_ line: String) {
        SpikeFileLog.append("fs3", line)
        log.append(line)
    }

    private static func seed() -> [FS3Project] {
        ["alpha", "beta", "gamma"].map { id in
            let titles = ["Backlog", "Dev", "Test", "Gate", "Review"]
            let columns: [FS3Column] = titles.enumerated().map { index, title in
                let cards: [FS3Card]
                if title == "Gate" {
                    cards = []
                } else {
                    cards = (0..<2).map { card in
                        FS3Card(
                            id: "\(id)-\(index)-\(card)",
                            title: "\(id.uppercased())-\(index)\(card)",
                            hasAcceptance: card == 0
                        )
                    }
                }
                return FS3Column(
                    id: "\(id)-\(title)",
                    title: title,
                    index: index,
                    collapsed: id == "alpha" && title == "Test",
                    isGate: title == "Gate",
                    cards: cards
                )
            }
            return FS3Project(id: id, name: id == "gamma" ? "Гамма (не на доске)" : id.capitalized, columns: columns)
        }
    }
}
