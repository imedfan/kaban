import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KabanProtocol
import KabanBoardCore

struct RunLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct RunLogSheet: View {
    @Bindable var store: BoardStore
    let initialRun: RunSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var selectedRun: RunSummary
    private var selectedRunID: RunID { selectedRun.id }
    @State private var followsLatest = true
    @State private var latestRequest = 0
    @State private var source: MaterialTextRoute?
    @State private var failure: String?
    @State private var readingSource = false
    @State private var exporting = false
    @State private var exportDocument = RunLogDocument(data: Data())
    @State private var presentsExport = false
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var log: RunLogStore { store.runLog }
    private var history: [RunSummary] { store.history(for: initialRun.taskId) }
    private var run: RunSummary { history.first { $0.id == selectedRunID } ?? selectedRun }
    init(store: BoardStore, run: RunSummary) {
        self.store = store; initialRun = run
        _selectedRun = State(initialValue: run)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").font(.system(size: 20)).foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40).background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Лог запуска").font(.system(size: 18, weight: .semibold))
                    Text(store.projection?.tasks[initialRun.taskId]?.title ?? initialRun.taskId.rawValue)
                        .font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(1)
                        .help(store.projection?.tasks[initialRun.taskId]?.title ?? initialRun.taskId.rawValue)
                }
                Spacer()
                KabanIconButton(symbol: "xmark", help: "Закрыть · Esc") { dismiss() }
            }
            HStack(spacing: 10) {
                Picker("Запуск", selection: Binding(get: { selectedRunID }, set: { id in
                    if let value = history.first(where: { $0.id == id }) { selectedRun = value }
                })) {
                    if !history.contains(where: { $0.id == selectedRunID }) {
                        Text(runLabel(selectedRun)).tag(selectedRunID)
                    }
                    ForEach(history, id: \.id) { value in Text(runLabel(value)).tag(value.id) }
                }.labelsHidden().frame(maxWidth: 350, alignment: .leading)
                Spacer()
                Text(run.actualModelName ?? "Модель не подтверждена").font(.system(size: 11))
                    .foregroundStyle(theme.secondary).lineLimit(1).help(run.actualModelName ?? "Модель не подтверждена")
            }
            HStack(spacing: 8) {
                Button("Ранее") { Task { await log.loadEarlier() } }.disabled(!log.canLoadEarlier)
                    .help("Загрузить предыдущую страницу. Наблюдение за новыми записями приостановится.")
                Button { store.logSearchRequest += 1 } label: { Label("Найти", systemImage: "magnifyingglass") }
                    .help("Поиск в загруженном фрагменте · ⌘F")
                Spacer()
                if log.isTailing { Label("Обновляется", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(theme.accent) }
                Button(followsLatest && log.mode == .latest ? "Внизу" : "К последним") {
                    Task { followsLatest = true; await log.showLatest(); latestRequest += 1 }
                }.disabled(log.state == .loading)
            }.buttonStyle(KabanButtonStyle(compact: true))
            status
            ZStack {
                RunLogTextView(runID: log.runID, entries: log.entries, mode: log.mode, dark: scheme == .dark,
                               searchRequest: store.logSearchRequest, scrollToLatestRequest: latestRequest,
                               followsLatest: $followsLatest, onOpenSource: openSource)
                    .accessibilityIdentifier("run-log-text")
                if log.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.page").font(.system(size: 24)).foregroundStyle(theme.faint)
                        Text(emptyTitle).font(.system(size: 13)).foregroundStyle(theme.secondary)
                    }.allowsHitTesting(false)
                }
            }.background(theme.card, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line, lineWidth: 0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rangeLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondary)
                    if log.entries.contains(where: \.requiresSeparateRead) {
                        Text("Крупные записи открываются отдельно и не входят в экспорт фрагмента.")
                            .font(.system(size: 10)).foregroundStyle(theme.faint)
                    }
                }
                Spacer()
                if let path = run.logPath, path.hasPrefix("/") {
                    Button("Сырой лог…") { openRawLog(path) }.help("Открыть файл из истории после предоставления доступа")
                }
                Button(exporting ? "Готовим…" : "Экспорт фрагмента…") { exportLoaded() }
                    .disabled(exporting || log.entries.allSatisfy(\.requiresSeparateRead))
            }.buttonStyle(KabanButtonStyle(compact: true))
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(theme.secondary).textSelection(.enabled).lineLimit(3).help(failure) }
            if readingSource { ProgressView("Читаем полную запись…").controlSize(.small) }
            HStack { Spacer(); Button("Закрыть") { dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 720, height: 552).background(theme.window)
            .task(id: selectedRunID) {
                failure = nil; source = nil; followsLatest = true
                await log.setConnectionAvailable(store.canSend)
                await log.setReadSupported(store.capabilities?.supportsOperation("readLog") == true)
                await log.select(selectedRunID)
            }
            .task(id: store.canSend) { await log.setConnectionAvailable(store.canSend) }
            .task(id: store.capabilities?.supportsOperation("readLog") == true) {
                await log.setReadSupported(store.capabilities?.supportsOperation("readLog") == true)
            }
            .task(id: source != nil) { await log.setVisible(source == nil) }
            .onDisappear { log.close() }
            .sheet(item: $source) { MaterialTextSheet(route: $0) }
            .fileExporter(isPresented: $presentsExport, document: exportDocument, contentType: .json,
                          defaultFilename: "kaban-run-\(selectedRunID.rawValue)-fragment") { result in
                if case .failure(let error) = result { failure = error.localizedDescription }
            }
    }
    @ViewBuilder private var status: some View {
        switch log.state {
        case .loading: ProgressView("Читаем записи…").controlSize(.small)
        case .waitingForConnection:
            Text("Связь прервана. Загруженный фрагмент сохранён; чтение продолжится после синхронизации.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
        case .expired(let offset):
            HStack(alignment: .top) {
                Text(offset.map { "Начало лога удалено. Служба хранит записи с №\($0)." } ?? "Старое смещение больше недоступно. Сохранённый диапазон неизвестен.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if offset != nil { Button("Читать доступное") { Task { await log.readAvailablePrefix() } }.buttonStyle(KabanButtonStyle(compact: true)) }
                else { Button("Проверить") { Task { await log.retry() } }.buttonStyle(KabanButtonStyle(compact: true)) }
            }
        case .unavailable(let error):
            HStack(alignment: .top) {
                Text(error.message).font(.system(size: 11)).foregroundStyle(theme.secondary).textSelection(.enabled)
                    .lineLimit(3).help(error.message)
                Spacer(); Button("Повторить") { Task { await log.retry() } }.buttonStyle(KabanButtonStyle(compact: true))
            }
        case .ready where log.mode == .history:
            Text("Просмотр истории · наблюдение за новыми записями приостановлено").font(.system(size: 10)).foregroundStyle(theme.faint)
        default: EmptyView()
        }
    }
    private var emptyTitle: String {
        switch log.state {
        case .loading: "Загружаем лог"
        case .expired: "Начало лога недоступно"
        case .unavailable: "Лог недоступен"
        case .waitingForConnection: "Ожидаем соединение"
        default: log.isComplete == true ? "В этом логе нет записей" : "Записей пока нет"
        }
    }
    private var rangeLabel: String {
        let loaded = log.entries.first.map { "\($0.offset)…\(log.entries.last!.offset + 1)" } ?? "—"
        let prefix = log.availableFromOffset.map(String.init) ?? "?"
        let end = log.endOffset.map(String.init) ?? "?"
        let completion = log.isComplete.map { $0 ? "завершён" : "не завершён" } ?? "исход неизвестен"
        return "Фрагмент \(loaded) · доступно с \(prefix) · конец \(end) · \(completion)"
    }
    private func runLabel(_ value: RunSummary) -> String {
        let stage = store.projection?.pipelines[store.projection?.tasks[value.taskId]?.projectId ?? ProjectID(rawValue: "")]?.stages.first { $0.id == value.stageId }?.name ?? value.stageId.rawValue
        return "\(stage) · запуск №\(value.number)"
    }
    private func openSource(_ offset: Int64) {
        guard !readingSource else { return }
        readingSource = true; failure = nil
        let runID = selectedRunID
        Task {
            defer { readingSource = false }
            do {
                let event = try await log.readFullRecord(at: offset)
                let value = try await Task.detached { () -> String in
                    let encoder = KabanCoding.makeEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return String(decoding: try encoder.encode(event), as: UTF8.self)
                }.value
                guard selectedRunID == runID, log.isVisible else { return }
                source = .init(id: "\(runID.rawValue):\(offset)", title: "Полная запись №\(offset)", text: value)
            } catch is CancellationError {} catch { if selectedRunID == runID { failure = error.localizedDescription } }
        }
    }
    private func exportLoaded() {
        guard !exporting else { return }; exporting = true; failure = nil
        let runID = selectedRunID
        Task {
            defer { exporting = false }
            do {
                let data = try await log.exportLoadedRecords()
                guard selectedRunID == runID, log.isVisible else { return }
                exportDocument = .init(data: data); presentsExport = true
            } catch { if selectedRunID == runID { failure = error.localizedDescription } }
        }
    }
    private func openRawLog(_ path: String) {
        let reported = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.directoryURL = reported.deletingLastPathComponent()
        panel.message = "Разрешите доступ к файлу лога, указанному в истории запуска."
        panel.prompt = "Открыть лог"; panel.nameFieldStringValue = reported.lastPathComponent
        let runID = selectedRunID
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let selected = panel.url, runID == selectedRunID, log.isVisible else { return }
            guard selected.standardizedFileURL.resolvingSymlinksInPath() == reported else {
                failure = "Выбран другой файл. Откройте путь из истории запуска."; return
            }
            let access = selected.startAccessingSecurityScopedResource()
            defer { if access { selected.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.isReadableFile(atPath: selected.path), NSWorkspace.shared.open(selected) else {
                failure = "Файл лога недоступен или не удалось открыть его в приложении."; return
            }
        }
    }
}

struct WIPRestoreRoute: Identifiable {
    let id = UUID()
    let request: WIPRestoreRequest
    let generation: UUID
    @MainActor init(store: BoardStore, card: TaskCard, run: RunSummary) {
        request = .init(card: card, run: run, pipeline: store.projection?.pipelines[card.projectId])
        generation = store.session.sessionGeneration
    }
}
struct WIPRestoreSheet: View {
    @Bindable var store: BoardStore
    let route: WIPRestoreRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var card: TaskCard { route.request.card }
    private var command: Command? {
        guard store.session.sessionGeneration == route.generation, store.session.pending(in: .task(card.id)) == nil else { return nil }
        return route.request.command(current: store.projection?.tasks[card.id], history: store.history(for: card.id),
                                     pipeline: store.projection?.pipelines[card.projectId])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 20)).foregroundStyle(theme.accent)
                    .frame(width: 42, height: 42).background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Восстановить WIP?").font(.system(size: 18, weight: .semibold))
                    Text("Запуск №\(route.request.run.number) · \(card.id.rawValue)").font(.system(size: 11)).foregroundStyle(theme.secondary)
                }
                Spacer(); KabanIconButton(symbol: "xmark", help: "Закрыть · Esc") { dismiss() }
            }
            Text(card.title).font(.system(size: 14, weight: .medium)).lineLimit(2).help(card.title)
            Text(route.request.run.wipRef ?? "WIP не указан").font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).lineLimit(3).truncationMode(.middle).help(route.request.run.wipRef ?? "")
                .contextMenu {
                    Button("Скопировать WIP") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(route.request.run.wipRef ?? "", forType: .string)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 9))
            Text("Служба восстановит дерево и index клона из этой попытки. Текущие правки клона сначала сохранятся в новый WIP.")
                .font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Main и исходная запись запуска сохранятся. Дождитесь подтверждения восстановления, прежде чем продолжать работу.")
                .font(.system(size: 11)).foregroundStyle(theme.faint).fixedSize(horizontal: false, vertical: true)
            if command == nil { Text("Задача, история или соединение изменились. Закройте окно и выберите WIP снова.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            if !store.can(.restoreWIP) { Text(store.unavailableReason(.restoreWIP)).font(.system(size: 11)).foregroundStyle(theme.secondary) }
            if let error = store.editorError { Text(error).font(.system(size: 11)).foregroundStyle(theme.secondary).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Восстановить WIP") {
                    Task {
                        guard let command, store.can(.restoreWIP) else { return }
                        if await store.send(command, taskID: card.id, editor: true) { dismiss() }
                    }
                }.buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(command == nil || !store.can(.restoreWIP)).accessibilityIdentifier("wip-restore-submit")
            }
        }.padding(20).frame(width: 560).background(theme.window)
    }
}
