import SwiftUI
import AppKit
import KabanProtocol
import KabanBoardCore

/// Reads durable artifacts; complete original text always remains available.
struct ReviewMaterialsView: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var artifacts: [TaskArtifact] { TaskDetailPresentation.summaryArtifacts(detail) }
    private var summaries: [TaskArtifact] {
        let stages = store.projection?.pipelines[detail.task.projectId]?.stages ?? []
        return artifacts.filter { $0.kind == "summary" }.sorted { firstArtifact, secondArtifact in
            let first = stages.firstIndex { $0.id == firstArtifact.stageId }
            let second = stages.firstIndex { $0.id == secondArtifact.stageId }
            return (first ?? Int.max, firstArtifact.createdAt, firstArtifact.id.rawValue) < (second ?? Int.max, secondArtifact.createdAt, secondArtifact.id.rawValue)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Клон задачи", systemImage: "folder").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Открыть в Cursor") { Task { await store.openClone(detail.clonePath) } }
                    .buttonStyle(KabanButtonStyle(compact: true)).disabled(detail.clonePath == nil || store.openingClone)
            }
            if let path = detail.clonePath {
                Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(path)
                Button("Скопировать путь") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }.buttonStyle(.link).font(.system(size: 11))
            } else { Text("Путь клона не передан службой").font(.system(size: 11)).foregroundStyle(theme.secondary) }
        }
        if detail.artifacts.isEmpty { Text("Материалов результата пока нет. Обновите детали или откройте доступный клон.").font(.system(size: 12)).foregroundStyle(theme.secondary) }
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Резюме стадий", systemImage: "text.alignleft").font(.system(size: 12, weight: .semibold))
                ForEach(summaries, id: \.id) { artifact in
                    HStack(alignment: .top, spacing: 12) {
                        Text(stageName(artifact)).font(.system(size: 11, weight: .semibold)).lineLimit(2).help(stageName(artifact)).frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 7) { originalText(artifact); sourceLinks(artifact) }.frame(maxWidth: .infinity, alignment: .leading)
                    }.id(artifact.id.rawValue)
                    if artifact.id != summaries.last?.id { Divider() }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 0.5))
        }
        ForEach(artifacts.filter { $0.kind != "summary" }, id: \.id) { artifact in
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Label(TaskDetailPresentation.artifactTitle(artifact.kind), systemImage: symbol(artifact.kind)).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let id = artifact.stageId { Text(store.projection?.pipelines[detail.task.projectId]?.stages.first { $0.id == id }?.name ?? id.rawValue).font(.system(size: 10)).foregroundStyle(theme.secondary) }
                }
                content(artifact)
                sourceLinks(artifact)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 0.5))
                .id(artifact.id.rawValue)
        }
        Text("Стоимость и расход токенов: нет данных от службы. Время каждого запуска — во вкладке «Запуски».")
            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func stageName(_ artifact: TaskArtifact) -> String {
        guard let id = artifact.stageId else { return "Неизвестная стадия" }
        return store.projection?.pipelines[detail.task.projectId]?.stages.first { $0.id == id }?.name ?? id.rawValue
    }
    @ViewBuilder private func sourceLinks(_ artifact: TaskArtifact) -> some View {
        if let path = artifact.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(2).help(path).textSelection(.enabled) }
        HStack(spacing: 8) {
            Button("Полный текст…") { store.materialTextRoute = .init(id: artifact.id.rawValue, title: TaskDetailPresentation.artifactTitle(artifact.kind), text: artifact.text) }
                .buttonStyle(.link).font(.system(size: 11))
            Spacer(minLength: 0)
            if let id = artifact.runId {
                if let run = detail.runs.first(where: { $0.id == id }) {
                    Button("Лог · №\(run.number)") { store.logRunRoute = run }.buttonStyle(.link).font(.system(size: 11)).help("Лог запуска №\(run.number)")
                } else { Text("Запуск: " + id.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1).help(id.rawValue) }
            }
        }
    }
    @ViewBuilder private func content(_ artifact: TaskArtifact) -> some View {
        if artifact.kind == "diffstat", let files = ReviewMaterialPresentation.files(artifact.text) {
            HStack {
                Text("Файл"); Spacer(); Text("+").frame(width: 42, alignment: .trailing); Text("−").frame(width: 42, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(theme.faint)
            ForEach(Array(files.prefix(8).enumerated()), id: \.offset) { _, file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(2).truncationMode(.middle).help(file.path).textSelection(.enabled)
                        Spacer(minLength: 6)
                        Text(file.additions.map(String.init) ?? "—").foregroundStyle(file.additions == nil ? theme.faint : theme.status("done").2).frame(width: 42, alignment: .trailing)
                        Text(file.deletions.map(String.init) ?? "—").foregroundStyle(theme.secondary).frame(width: 42, alignment: .trailing)
                    }.font(.system(size: 11, design: .monospaced))
                    if file.binary { Text("Двоичный файл · число строк неизвестно").font(.system(size: 10)).foregroundStyle(theme.faint) }
                    else if file.additions == nil { Text("\(file.changes.map(String.init) ?? "?") изменений · точные +/− не переданы").font(.system(size: 10)).foregroundStyle(theme.faint) }
                    else if let add = file.additions, let del = file.deletions, let total = file.changes, total > 0 {
                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                theme.status("done").2.frame(width: geometry.size.width * Double(add) / Double(total))
                                theme.status("incident").2.frame(width: geometry.size.width * Double(del) / Double(total))
                            }
                        }.frame(width: 80, height: 3).clipShape(Capsule())
                    }
                }.padding(.vertical, 2)
            }
            if files.count > 8 { Text("Ещё \(files.count - 8) файлов в полном источнике").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            Text("В этом списке: \(files.count) файлов. Пути могут быть сокращены.").font(.system(size: 10)).foregroundStyle(theme.faint)
        } else if artifact.kind == "commits", let commits = ReviewMaterialPresentation.commits(artifact.text) {
            ForEach(Array(commits.prefix(6).enumerated()), id: \.offset) { _, commit in
                VStack(alignment: .leading, spacing: 3) {
                    Text(commit.subject).font(.system(size: 11)).lineLimit(3).textSelection(.enabled)
                    Text(commit.sha).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1).truncationMode(.middle).help(commit.sha).textSelection(.enabled)
                }
            }
            if commits.count > 6 { Text("Ещё \(commits.count - 6) коммитов в полном источнике").font(.system(size: 11)).foregroundStyle(theme.secondary) }
        } else if artifact.kind == "merge_result", let result = MergePresentation.result(detail) {
            Text(result.ref).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(result.commit).font(.system(size: 10, design: .monospaced)).lineLimit(2).textSelection(.enabled).help(result.commit)
            DisclosureGroup("Предыдущий commit основной ветки") { Text(result.baseCommit).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }.font(.system(size: 11))
        } else if let conflict = MergePresentation.conflict(artifact) {
            ForEach(Array(conflict.files.prefix(10).enumerated()), id: \.offset) { _, path in
                Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
            }
            if conflict.files.count > 10 { Text("Ещё \(conflict.files.count - 10) файлов в полном источнике").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            Text("Файлы конфликта на момент rebase. Правки при разрешении оцениваются в новом результате и Human Review.").font(.system(size: 11)).foregroundStyle(theme.secondary)
        } else if artifact.kind == "gate_output" || artifact.kind == "merge_gate_output" {
            if artifact.text.utf8.count > TaskDetailPresentation.largeTextBytes { originalText(artifact) }
            else { GateOutputReviewView(text: artifact.text) }
        } else {
            if artifact.kind == "commits" { Text("SHA и список коммитов неизвестны. Ниже — исходный материал.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            if artifact.kind == "diffstat" { Text("Число файлов и точные +/− неизвестны. Ниже — исходный материал.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            originalText(artifact)
        }
    }
    @ViewBuilder private func originalText(_ artifact: TaskArtifact) -> some View {
        if artifact.text.utf8.count > TaskDetailPresentation.largeTextBytes {
            Text("Большой материал · \(ByteCountFormatter.string(fromByteCount: Int64(artifact.text.utf8.count), countStyle: .file)). Откройте полный текст.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
        } else if artifact.text.isEmpty { Text("Материал без текста").font(.system(size: 11)).foregroundStyle(theme.faint) }
        else { Text(artifact.text).font(.system(size: 11, design: artifact.kind == "summary" ? .default : .monospaced)).lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
    private func symbol(_ kind: String) -> String {
        switch kind { case "summary": "text.alignleft"; case "diffstat": "doc"; case "commits": "arrow.triangle.branch"; case "gate_output": "checklist"; default: "doc.text" }
    }
}

private struct GateOutputReviewView: View {
    let text: String
    @State private var expanded = BoardQA.argument("--qa-review") == "gates"
    var body: some View {
        DisclosureGroup("Показать вывод проверки", isExpanded: $expanded) {
            Text(text).font(.system(size: 11, design: .monospaced)).lineLimit(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
