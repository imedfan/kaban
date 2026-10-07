import AppKit
import KabanProtocol
import KabanBoardCore

/// Explicit failure fixtures around the same typed mock client, only for QA.
@MainActor final class QAHumanAnswerClient: KabanClient {
    let base: MockKabanClient
    var mode: String
    var questionChanged = false
    var lostOnce = false
    var sent: [CommandEnvelope] = []
    private var continuation: AsyncThrowingStream<KabanClientUpdate, Error>.Continuation?
    init(base: MockKabanClient, mode: String) { self.base = base; self.mode = mode }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let stream = base.updates()
        return AsyncThrowingStream { sink in
            continuation = sink
            let forward = Task { @MainActor in
                do { for try await update in stream { sink.yield(update) } }
                catch { sink.finish(throwing: error) }
            }
            sink.onTermination = { @Sendable _ in forward.cancel() }
        }
    }
    func disconnect(lastSeq: Seq?) { continuation?.yield(.connection(.reconnecting(lastSeq: lastSeq))) }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities { try await base.capabilities() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .answerHuman = envelope.command {
            sent.append(envelope)
            switch mode {
            case "pending": return .init(commandId: envelope.commandId, seq: nil, result: .ok)
            case "stale":
                questionChanged = true
                return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "invalid_state", message: "Вопрос уже закрыт или принадлежит другому запуску.")))
            case "error": return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "policy_blocked", message: "Служба отклонила ответ. Черновик сохранён; проверьте состояние задачи перед повторной отправкой.")))
            case "lost" where !lostOnce:
                lostOnce = true; _ = try await base.send(envelope)
                throw CommandError(code: "connection_lost", message: "Reply lost after commit")
            default: break
            }
        }
        var reply = try await base.send(envelope)
        if questionChanged, case .taskDetail(var detail) = reply.result {
            detail.humanRequests.append(.init(requestId: "qa-new-question", taskId: detail.task.id, runId: nil, question: "Новый вопрос: разрешено ли повторить возврат после проверки статуса?"))
            reply.result = .taskDetail(detail)
        }
        return reply
    }
}

extension BoardQA {
    static var answerClient: QAHumanAnswerClient?
    static func prepareAnswer(_ store: BoardStore) async throws -> Bool {
        guard let mode = argument("--qa-answer") else { return false }
        await store.select("SHOP-31")
        if !["human", "gate", "merge", "running", "gating"].contains(mode) {
            let text = mode == "empty" ? "" : mode == "long" ? String(repeating: "Сначала проверь статус возврата. Сохрани результат проверки и объясни, что изменилось. 👋\n", count: 50) : mode == "suspicious" ? "Убери из ветки: .env.local" : "Сначала проверь состояние возврата. Повторяй запрос только если платёж ещё не возвращён."
            store.humanAnswers.setText(text, for: "SHOP-31")
        }
        if ["pending", "stale", "error"].contains(mode) { _ = await store.humanAnswers.submit("SHOP-31") }
        if mode == "offline" {
            answerClient?.disconnect(lastSeq: store.projection?.stateSeq)
            try await waitUntil("answer disconnected") { !store.canSend }
        }
        if mode == "answered" {
            _ = await store.humanAnswers.submit("SHOP-31")
            try await waitUntil("answer confirmation") { store.humanAnswers.receipt(for: "SHOP-31")?.phase == .applied }
            await store.session.retryDetail(); store.detailTab = "Лента"
        }
        return true
    }
    static func answerSmoke(_ store: BoardStore) async throws -> [String] {
        guard let client = answerClient, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Answer WindowGroup missing") }
        await store.select("SHOP-31"); window.makeKeyAndOrderFront(nil); NSApp.activate()
        try await Task.sleep(for: .milliseconds(350))
        func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        guard let editor = window.contentView.flatMap({ editors($0).first { !$0.isFieldEditor && $0.isEditable } }) else { throw failure("Native answer editor missing") }
        let text = "Сначала проверить состояние  \r\n👋"
        window.makeFirstResponder(editor); editor.string = text; editor.didChangeText()
        try await waitUntil("native input saved") { store.humanAnswers.draft(for: "SHOP-31")?.text == text }
        client.mode = "stale"
        NSApp.mainMenu?.update()
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36), NSApp.mainMenu?.performKeyEquivalent(with: key) == true else { throw failure("Native Cmd-Return answer route missing") }
        try await waitUntil("stale answer refresh") { store.detail?.humanRequests.last?.requestId == "qa-new-question" }
        guard store.humanAnswers.draft(for: "SHOP-31")?.text == text, store.humanAnswers.isStale("SHOP-31"), !store.humanAnswers.canSubmit("SHOP-31") else { throw failure("Stale answer retargeted or lost text") }
        client.mode = "lost"; client.questionChanged = false; await store.session.retryDetail()
        guard store.humanAnswers.canSubmit("SHOP-31") else { throw failure("Original question cannot resume") }
        _ = await store.humanAnswers.submit("SHOP-31")
        try await waitUntil("lost reply correlation") { store.humanAnswers.receipt(for: "SHOP-31")?.phase == .applied && store.canSend }
        await store.session.retryDetail()
        guard store.detail?.feed.filter({ $0.kind == "answer" }).map(\.text) == [text], store.projection?.tasks["SHOP-31"]?.state == .queued(nil), Set(client.sent.dropFirst().map(\.commandId)).count == 1 else { throw failure("Answer history/correlation/replay failed") }
        await store.select(nil); await store.select("SHOP-31")
        guard store.detail?.feed.filter({ $0.kind == "answer" }).count == 1 else { throw failure("Reopening lost answer") }
        store.detailTab = "Лента"
        if argument("--export-live-window") != nil { try await captureWindow() }
        return ["real WindowGroup native answer TextEditor preserves CRLF and Unicode", "Cmd-Return sends one typed answer to its specific requestId", "stale refusal refreshes details and retains original text and question", "lost receipt reconciles the exact commandId without duplicate answer", "correlated taskUpdated queues the task; reopening retains the answer feed", "fixtures only; no Cursor process launched"]
    }
    static func answerLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = argument("--answer-live-fixture"),
              let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String],
              let question = metadata["question"], let stale = metadata["stale"], let files = metadata["files"], let old = metadata["oldRequest"] else { throw failure("Isolated answer metadata missing") }
        let text = "Check the refund status first.  \r\nContinue safely 👋", note = "Remove .env.local from the branch."
        if CommandLine.arguments.contains("--answer-live-reopen") {
            for (id, expected) in [(question, text), (files, note)] {
                await store.select(TaskID(rawValue: id))
                guard store.detail?.feed.filter({ $0.kind == "answer" && $0.text == expected }).count == 1,
                      store.detail?.task.state == .queued(nil) else { throw failure("Durable answer missing after daemon restart and retention") }
            }
            guard store.detail?.acceptedFiles.isEmpty == true else { throw failure("Note accepted files on reopening") }
            store.detailTab = "Лента"
            if argument("--export-live-window") != nil { try await captureWindow() }
            return ["private bundled daemon restarted after journal deletion", "durable exact question answer and nil-request note read from getTaskDetail", "files remain unaccepted after restart", "Cursor not launched; tasks kept queued by pauseAll"]
        }
        await store.select(TaskID(rawValue: question))
        store.humanAnswers.setText(text, for: TaskID(rawValue: question))
        guard store.humanAnswers.canSubmit(TaskID(rawValue: question)) else { throw failure("Live question cannot answer") }
        _ = await store.humanAnswers.submit(TaskID(rawValue: question))
        try await waitUntil("live answer journal confirmation") { store.humanAnswers.receipt(for: TaskID(rawValue: question))?.phase == .applied }
        await store.session.retryDetail()
        guard store.detail?.feed.filter({ $0.kind == "answer" && $0.text == text }).count == 1 else { throw failure("Live answer missing from durable feed") }
        await store.select(TaskID(rawValue: stale))
        store.humanAnswers.setText("Preserve this draft", for: TaskID(rawValue: stale))
        let rejected = await store.session.send(.answerHuman(taskId: TaskID(rawValue: stale), text: "Old request answer", requestId: HumanRequestID(rawValue: old)), editor: true)
        guard !rejected, store.humanAnswers.draft(for: TaskID(rawValue: stale))?.text == "Preserve this draft" else { throw failure("Stale live request accepted or draft lost") }
        await store.session.retryDetail()
        guard store.detail?.feed.contains(where: { $0.text == "Old request answer" }) == false else { throw failure("Refused answer added to feed") }
        store.error = nil
        await store.select(TaskID(rawValue: files))
        guard store.detail?.task.suspiciousFiles.isEmpty == false else { throw failure("Live suspicious fixture missing") }
        let acceptedBefore = store.detail?.acceptedFiles
        store.humanAnswers.setText(note, for: TaskID(rawValue: files))
        _ = await store.humanAnswers.submit(TaskID(rawValue: files))
        try await waitUntil("live note journal confirmation") { store.humanAnswers.receipt(for: TaskID(rawValue: files))?.phase == .applied }
        guard case .answerHuman(_, _, nil) = store.humanAnswers.receipt(for: TaskID(rawValue: files))?.envelope.command else { throw failure("Live note bound to question") }
        await store.session.retryDetail()
        guard store.detail?.task.state == .queued(nil), store.detail?.acceptedFiles == acceptedBefore,
              store.detail?.feed.filter({ $0.kind == "answer" && $0.text == note }).count == 1 else { throw failure("Live note accepted files or lost durable text") }
        store.detailTab = "Лента"
        if argument("--export-live-window") != nil { try await captureWindow() }
        return ["real bundled daemon over private stdio, isolated git repo/database", "specific requestId answer commits durable feed and correlated taskUpdated", "stale requestId rejected without feed entry or draft loss", "nil-request note queues same agent stage without adding accepted file blobs", "pauseAll keeps new starts stopped; no Cursor run initiated by acceptance"]
    }
}
