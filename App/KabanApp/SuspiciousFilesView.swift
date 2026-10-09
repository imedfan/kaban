import SwiftUI
import KabanProtocol
import KabanBoardCore

struct SuspiciousReturnRoute: Identifiable { let taskID: TaskID; var id: TaskID { taskID } }
enum TaskDetailAnchor: Hashable { case suspiciousActions, humanAnswer }

struct SuspiciousFilesView: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    let theme: KabanTheme
    @State private var historyExpanded = false
    private var context: SuspiciousFilesContext? { store.suspiciousFiles.context(for: detail.task.id) }
    private var pending: Bool { store.session.pending(in: .task(detail.task.id)) != nil }
    private var stale: [FileBlobRef]? { store.suspiciousFiles.staleFiles(for: detail.task.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if detail.task.state == .waitingHuman(.suspiciousFiles) {
                Label("В ветке подозрительные файлы · \(detail.suspiciousFiles.count)", systemImage: "exclamationmark.shield")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.status("waiting").2)
                Text(checkLabel).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                if let old = stale {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Набор файлов изменился — ничего не принято", systemImage: "info.circle").font(.system(size: 12, weight: .medium))
                        let removed = old.filter { value in !detail.suspiciousFiles.contains { $0.path == value.path } }.map(\.path)
                        if !removed.isEmpty { Text("Убраны: " + removed.joined(separator: ", ")).font(.system(size: 11)) }
                    }.foregroundStyle(theme.status("waiting").2)
                }
                if detail.suspiciousFiles.isEmpty { Text("Подозрительных файлов больше нет. Подтвердите новый пустой набор, чтобы продолжить.").font(.system(size: 11)) }
                ForEach(detail.suspiciousFiles, id: \.path) { file in fileRow(file) }
                if let error = store.fileOpeningError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                if let context {
                    Button(pending ? "Ожидаем подтверждение…" : "Принять файлы (\(context.files.count))") { Task { await store.suspiciousFiles.accept(context) } }
                        .buttonStyle(KabanButtonStyle(primary: true)).disabled(!store.suspiciousFiles.canAccept(context))
                        .accessibilityIdentifier("suspicious-accept")
                        .id(TaskDetailAnchor.suspiciousActions)
                    Text("Kaban перепроверит ветку и продолжит отложенный переход без нового запуска агента.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    if context.stage?.kind == .agent {
                        Button("Попросить убрать") {
                            store.prepareFileRemoval(context)
                        }.buttonStyle(KabanButtonStyle(compact: true)).disabled(pending)
                        Text("Набор не принимается. Проверьте и отправьте замечание агенту ниже; после нового запуска файлы проверяются снова.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if context.canReturn {
                        Button("Вернуть…") { store.suspiciousReturnRoute = .init(taskID: detail.task.id) }
                            .buttonStyle(KabanButtonStyle(compact: true)).disabled(pending)
                            .accessibilityIdentifier("suspicious-return")
                    } else if context.stage?.kind == .gate || context.stage?.kind == .merge {
                        Text("Для возврата служба должна сообщить сохранённый pipeline этой задачи.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                    }
                    HStack {
                        Button("Перезапустить") { store.beginControl(detail.task, action: .retry) }
                        Button("В Backlog") {
                            if let target = context.pipeline.stages.first(where: { $0.kind == .queue })?.id { store.beginControl(detail.task, action: .move(target)) }
                        }.disabled(!context.pipeline.stages.contains(where: { $0.kind == .queue }))
                        Button("Отменить…") { store.beginControl(detail.task, action: .cancel) }
                    }.buttonStyle(KabanButtonStyle(compact: true)).disabled(pending)
                    Text("Эти действия примут текущий набор. Изменённый или новый файл сработает снова.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                } else { Text("Для действий нужны актуальные детали и pipeline. Обновите данные задачи.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                if let record = store.suspiciousFiles.acceptance(for: detail.task.id), case .rejected(let error) = record.phase, stale == nil {
                    Text(error.message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                }
                Divider()
            }
            DisclosureGroup("Принятые ранее · \(detail.acceptedFiles.count)", isExpanded: $historyExpanded) {
                if detail.acceptedFiles.isEmpty { Text("Принятых файлов пока нет.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                ForEach(Array(detail.acceptedFiles.enumerated()), id: \.offset) { _, file in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Text(String(file.blob.prefix(10))).font(.system(size: 10, design: .monospaced)).help(file.blob)
                            Text(file.by == .human ? "вы" : file.by.rawValue)
                            Text(acceptedDate(file.at))
                        }.font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.system(size: 12))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.status("waiting").0.opacity(0.4), lineWidth: 0.5))
            .onAppear { historyExpanded = detail.task.state != .waitingHuman(.suspiciousFiles) }
            .onChange(of: detail.acceptedFiles) { _, files in if !files.isEmpty { historyExpanded = true } }
    }
    private var checkLabel: String {
        guard let check = detail.fileCheck else { return "Проверка diff ветки; база, порог размера и Strict неизвестны службе." }
        return "Весь diff ветки от базы " + (check.baseCommit.map { String($0.prefix(10)) } ?? "неизвестна")
            + (check.includesUncommitted ? "; Strict включает незакоммиченные файлы." : ".")
    }
    private func acceptedDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "ru_RU")
        format.timeZone = TimeZone(identifier: "Europe/Kaliningrad")
        format.dateFormat = "d MMM yyyy, HH:mm"
        return format.string(from: date) + " · Калининград"
    }
    private func fileRow(_ file: SuspiciousFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let old = stale, !old.contains(where: { $0.path == file.path && $0.blob == file.blob }) {
                    Text(old.contains(where: { $0.path == file.path }) ? "изменён" : "новый")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.status("waiting").2)
                }
            }
            HStack {
                Text(file.rule == .pattern ? "по шаблону \(file.pattern ?? "неизвестен")" : sizeRule)
                Spacer(minLength: 4)
                Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
            }.font(.system(size: 10)).foregroundStyle(theme.secondary)
            Text("blob · " + String(file.blob.prefix(10))).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).help(file.blob)
            HStack {
                Button(SuspiciousFilesContext.canPreview(file, check: detail.fileCheck) ? "Дифф в Cursor" : "Показать в Finder") {
                    Task { await store.openSuspiciousFile(file, detail: detail) }
                }.disabled(pending)
                Spacer(minLength: 4)
                Button("В исключения проекта…") { Task { await store.openFileException(file.path, project: detail.task.projectId) } }
                    .disabled(pending || !store.can(.getPipelineSource))
            }.buttonStyle(KabanButtonStyle(compact: true))
        }.padding(9).background(theme.card, in: RoundedRectangle(cornerRadius: 7))
    }
    private var sizeRule: String {
        detail.fileCheck.map { "больше " + ByteCountFormatter.string(fromByteCount: $0.maxFileBytes, countStyle: .file) } ?? "превышен неизвестный порог размера"
    }
}

extension BoardStore {
    func prepareFileRemoval(_ context: SuspiciousFilesContext) {
        guard suspiciousFiles.context(for: context.card.id) == context, context.stage?.kind == .agent else { return }
        humanAnswers.setText(context.removalText, for: context.card.id)
        detailTab = "Описание"; detailScrollTarget = .humanAnswer
    }
    func openFileException(_ path: String, project: ProjectID) async {
        let editor = pipelineEditor(for: project)
        editingPipelineProject = project; selectedProjectID = project; screen = .project(project)
        editor.selectedStageID = "__files"
        await editor.loadIfNeeded()
        guard !editor.isPending, let values = editor.document.stringList("suspicious_files.allow"), !values.contains(path) else { return }
        if let data = try? JSONEncoder().encode(values + [path]), let yaml = String(data: data, encoding: .utf8) {
            editor.patch("suspicious_files.allow", value: yaml)
        }
    }
    @discardableResult func openSuspiciousFile(_ file: SuspiciousFile, detail: TaskDetail) async -> Bool {
        guard selectedID == detail.task.id, session.detailReadState == .loaded, self.detail == detail else { return false }
        fileOpeningError = nil
        do {
            let target = try TaskFileAccess.validate(clonePath: detail.clonePath, relativePath: file.path)
            if !SuspiciousFilesContext.canPreview(file, check: detail.fileCheck) {
                NSWorkspace.shared.activateFileViewerSelecting([target.url]); return true
            }
            guard let maximum = detail.fileCheck?.maxFileBytes, target.size < maximum else {
                throw CommandError(code: "file_changed", message: "Файл вырос после проверки. Обновите детали или покажите его в Finder.")
            }
            guard let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") else {
                throw CommandError(code: "cursor_unavailable", message: "Cursor не найден. Установите редактор или покажите файл в Finder.")
            }
            let error: String? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.open([target.url], withApplicationAt: cursor, configuration: .init()) { _, failure in continuation.resume(returning: failure?.localizedDescription) }
            }
            if selectedID == detail.task.id { fileOpeningError = error }
            return error == nil
        } catch {
            if selectedID == detail.task.id { fileOpeningError = (error as? CommandError)?.message ?? error.localizedDescription }
            return false
        }
    }
}
