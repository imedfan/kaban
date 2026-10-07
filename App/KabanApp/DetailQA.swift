import AppKit
import KabanProtocol
import KabanBoardCore

/// Explicit inspector fixtures; never substitutes for a production daemon session.
@MainActor final class QADetailClient: KabanClient {
    let base: MockKabanClient
    var mode: String
    var seq: Seq = 0
    var revision = 0
    private var continuation: AsyncThrowingStream<KabanClientUpdate, Error>.Continuation?
    init(base: MockKabanClient, mode: String) { self.base = base; self.mode = mode }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let updates = base.updates()
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            let forward = Task { @MainActor in
                do { for try await update in updates { continuation.yield(update) } }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in forward.cancel() }
        }
    }
    func publish(_ event: EventEnvelope) { continuation?.yield(.event(event)) }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities {
        var value = try await base.capabilities()
        value.commands.removeAll { $0.name == CommandName.getRunHistory.rawValue }
        value.commands.append(.init(name: CommandName.getRunHistory.rawValue, support: .supported))
        value.operations.append(.init(name: "readLog", supported: true))
        return value
    }
    func run(_ id: TaskID) -> RunSummary {
        .init(id: "qa-detail-run", taskId: id, stageId: "dev", number: 2, status: .succeeded, requestedModel: "composer-1",
              actualModelName: nil, startedAt: Date(timeIntervalSince1970: 1_791_375_000), endedAt: Date(timeIntervalSince1970: 1_791_375_120), logPath: "/private/qa/agent/run-2.jsonl")
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .getRunHistory(let id) = envelope.command { return .init(commandId: envelope.commandId, seq: nil, result: .runs([run(id)])) }
        let reply = try await base.send(envelope)
        guard case .taskDetail(var detail) = reply.result else { return reply }
        if mode == "loading" { try await Task.sleep(for: .seconds(120)) }
        if mode == "unavailable" || mode == "too-large" {
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: mode == "too-large" ? CommandError.detailTooLargeCode : "detail_unavailable", message: mode == "too-large" ? "Сохранённые материалы превышают размер одного ответа." : "Не удалось прочитать материалы. Повторите чтение.", params: ["bytes": "9200000", "limit": "8388608"])))
        }
        detail.seq = seq
        detail.task.title = "Платёжный шлюз: проверить возвраты, вебхуки и сохранность результата при повторной доставке"
        if mode == "empty" { detail.body = ""; detail.feed = []; detail.artifacts = []; detail.runs = []; return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(detail)) }
        let run = run(detail.task.id), at = run.startedAt
        detail.runs = [run]
        detail.body = "# Интеграция платёжного шлюза\n\nПроверить повторную доставку и вернуть понятный результат.\n\n## Критерии приёмки\n- [ ] Один возврат на один платёж.\n- [ ] Подпись вебхука проверяется.\n\n~~~swift\nlet message = \"Привет 👋\"\n~~~\n"
        detail.humanRequests = [.init(requestId: "qa-question", taskId: detail.task.id, runId: run.id, question: "Повторять возврат при сетевой ошибке или сначала проверить его состояние?")]
        detail.feed = [
            .init(id: "1", at: at, kind: "question", text: detail.humanRequests[0].question, runId: run.id),
            .init(id: "2", at: at.addingTimeInterval(10), kind: "answer", text: "Сначала проверять состояние возврата.", runId: run.id),
            .init(id: "3", at: at.addingTimeInterval(20), kind: "progress", text: revision == 0 ? "Добавлены проверки повторной доставки." : "Новый прогресс появился в открытой панели.", runId: run.id),
            .init(id: "4", at: at.addingTimeInterval(30), kind: "future_event", text: "Новый вид события сохранён как текст.", runId: run.id)
        ]
        detail.clonePath = nil
        detail.artifacts = [
            .init(id: "summary", taskId: detail.task.id, runId: run.id, stageId: "dev", kind: "summary", text: "Добавлена идемпотентная обработка возвратов. Повторный webhook не создаёт второй платёж.", createdAt: at),
            .init(id: "gate", taskId: detail.task.id, runId: run.id, stageId: "test", kind: "gate_output", text: revision == 0 ? "swift test\n42 tests passed · exit 0" : "Новый gate output · 43 tests passed", createdAt: at),
            .init(id: "commits", taskId: detail.task.id, runId: run.id, stageId: "dev", kind: "commits", text: "abc1234 Add refund idempotency", createdAt: at),
            .init(id: "diffstat", taskId: detail.task.id, kind: "diffstat", text: "Refund.swift | +48 -12\nWebhook.swift | +7 -3", createdAt: at),
            .init(id: "hook", taskId: detail.task.id, kind: "hook", text: "format check passed", createdAt: at),
            .init(id: "issue", taskId: detail.task.id, kind: "issue", text: "Проверить timeout для внешнего провайдера.", createdAt: at),
            .init(id: "unknown", taskId: detail.task.id, kind: "future_material", text: mode == "large-artifact" ? String(repeating: "Точный текст без усечения 👋\n", count: 4_000) : "Исходный текст нового материала.", createdAt: at, path: "/metadata/only/не-читать-автоматически.txt")
        ]
        if mode == "large-artifact" || mode == "unknown" { detail.artifacts = Array(detail.artifacts.suffix(1)) }
        return .init(commandId: envelope.commandId, seq: nil, result: .taskDetail(detail))
    }
    func readLog(runId: RunID, fromOffset: Int64, limit: Int) async throws -> LogPage {
        guard runId == "qa-detail-run" else { throw CommandError(code: "log_unavailable", message: "Лог недоступен.") }
        return .init(batch: .init(runId: runId, fromOffset: fromOffset, nextOffset: fromOffset + 1, events: [.message(role: "assistant", text: "Отдельное чтение лога доступно при слишком больших деталях.")]), availableFromOffset: 0, endOffset: fromOffset + 1, isComplete: true)
    }
}
extension BoardQA {
    static var detailClient: QADetailClient?
    static func prepareDetails(_ store: BoardStore) async throws -> Bool {
        guard let mode = argument("--qa-detail") else { return false }
        if mode == "loading" {
            Task { await store.select("SHOP-31") }
            try await waitUntil("detail loading") { store.selectedID != nil && store.session.detailReadState == .loading }
        } else { await store.select("SHOP-31") }
        store.detailTab = argument("--qa-detail-tab") ?? (mode == "too-large" ? "Запуски" : "Сводка")
        if mode == "too-large" { await store.session.readRunHistory() }
        if mode == "material", let artifact = store.detail?.artifacts.last { store.materialTextRoute = .init(id: artifact.id.rawValue, title: "Материал · future_material", text: artifact.text) }
        if mode == "log", let run = store.detail?.runs.first { store.logRunRoute = run }
        return true
    }
    static func detailLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = argument("--detail-live-fixture"),
              let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String],
              let question = metadata["questionTask"], let summary = metadata["summaryTask"], let body = metadata["body"] else { throw failure("Isolated detail metadata missing") }
        await store.select(TaskID(rawValue: question))
        guard let detail = store.detail, detail.body?.utf8.elementsEqual(body.utf8) == true,
              detail.humanRequests.contains(where: { $0.question == "Where should the note go?" }),
              detail.feed.contains(where: { $0.kind == "answer" && $0.text == "In the durable feed." }) else { throw failure("Retained question/answer/body missing through real daemon") }
        await store.session.readRunHistory()
        guard let run = store.session.runHistory?.first else { throw failure("Real run history missing") }
        let page = try await store.readLog(runId: run.id, fromOffset: 0, limit: 100)
        guard page.batch.events == [.message(role: "assistant", text: "Durable log record")] else { throw failure("Real log read failed") }
        await store.select(TaskID(rawValue: summary))
        guard store.detail?.artifacts.contains(where: { $0.kind == "summary" && $0.text == "Durable summary survives journal retention." }) == true else { throw failure("Durable summary missing") }
        store.detailTab = "Сводка"
        if argument("--export-live-window") != nil { try await captureWindow() }
        return ["bundled stdio daemon and private database after journal deletion", "exact Markdown, persisted question and answer through getTaskDetail", "getRunHistory and readLog independent of detail query", "durable stage summary after reopening the daemon", "Cursor not launched; run records seeded through store APIs"]
    }
    static func detailSmoke(_ store: BoardStore) async throws -> [String] {
        guard let client = detailClient, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Detail WindowGroup missing") }
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        await store.select("SHOP-31")
        guard store.detail?.artifacts.count == 7, store.detail?.feed.count == 4, store.detail?.clonePath == nil else { throw failure("Durable material read incomplete") }
        let body = store.detail?.body
        store.detailTab = "Лента"; client.revision = 1; client.seq = (store.projection?.stateSeq ?? 0) + 1
        client.publish(.init(seq: client.seq, at: Date(), projectId: "shop", event: .humanRequested(.init(requestId: "qa-question", taskId: "SHOP-31", runId: "qa-detail-run", question: "Refresh"))))
        try await waitUntil("question/progress/material refresh") { store.detail?.artifacts.contains { $0.text.contains("43 tests") } == true }
        client.mode = "too-large"; await store.session.retryDetail()
        guard case .unavailable(let readFailure) = store.session.detailReadState, readFailure.code == CommandError.detailTooLargeCode, store.detail?.body == body else { throw failure("Failure discarded original text") }
        await store.session.readRunHistory()
        guard let run = store.session.runHistory?.first else { throw failure("Separate history missing") }
        let page = try await store.readLog(runId: run.id, fromOffset: 0, limit: 100)
        guard page.batch.events.count == 1 else { throw failure("Separate log missing") }
        client.mode = "summary"; await store.session.retryDetail(); store.detailTab = "Сводка"
        let exact = String(repeating: "Complete source\n", count: 5_000)
        store.materialTextRoute = .init(id: "complete", title: "Полный текст", text: exact)
        try await waitUntil("material text sheet") { window.attachedSheet != nil }
        func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        guard let textView = window.attachedSheet?.contentView.flatMap({ textViews($0).first }), textView.string == exact, !textView.isEditable else { throw failure("Full material missing or editable") }
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.attachedSheet?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
              window.attachedSheet?.performKeyEquivalent(with: escape) == true else { throw failure("Material Escape missing") }
        try await waitUntil("material sheet closed") { window.attachedSheet == nil }
        await store.select(nil)
        return ["actual WindowGroup inspector and four tabs", "question event refreshes progress and gate output without reopening", "detail_too_large keeps exact body and has separate history/log reads", "unknown material/feed kinds and nil clonePath remain readable", "full readonly source text and native Escape sheet dismissal"]
    }
}
