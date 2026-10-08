import AppKit
import KabanProtocol
import KabanBoardCore

@MainActor final class QAHumanReviewClient: KabanClient {
    let base: MockKabanClient
    var mode: String
    var materialChanged = false
    var lostOnce = false
    var sent: [CommandEnvelope] = []
    private var continuation: AsyncThrowingStream<KabanClientUpdate, Error>.Continuation?
    init(base: MockKabanClient, mode: String) { self.base = base; self.mode = mode }
    private func snapshot(_ value: Snapshot) -> Snapshot {
        var value = value
        if ["nil-default", "pipeline-issues"].contains(mode), let index = value.pipelines.firstIndex(where: { $0.projectId == "shop" }) {
            value.pipelines[index].defaultReturnStage = nil
            value.pipelines[index].issues = [.init(path: "stages", code: "no_return_target", message: "Нет стадии для возврата с комментарием", severity: .error)]
        }
        return value
    }
    func getSnapshot() async throws -> Snapshot { snapshot(try await base.getSnapshot()) }
    func synchronize() async throws -> SnapshotReplacement { var value = try await base.synchronize(); value.snapshot = snapshot(value.snapshot); return value }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let stream = base.updates()
        return AsyncThrowingStream { sink in
            continuation = sink
            let forward = Task { @MainActor in
                do { for try await update in stream { sink.yield(update) } } catch { sink.finish(throwing: error) }
            }
            sink.onTermination = { @Sendable _ in forward.cancel() }
        }
    }
    func disconnect(lastSeq: Seq?) { continuation?.yield(.connection(.reconnecting(lastSeq: lastSeq))) }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities { try await base.capabilities() }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        switch envelope.command {
        case .approve, .requestChanges, .reject:
            sent.append(envelope)
            if mode == "pending" { return .init(commandId: envelope.commandId, seq: nil, result: .ok) }
            if mode == "stale" {
                materialChanged = true
                return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "invalid_state", message: "Результат обновлён другим клиентом. Проверьте новые материалы.")))
            }
            if mode == "error" { return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "policy_blocked", message: "Служба не разрешила решение. Комментарий сохранён."))) }
            if mode == "lost", !lostOnce {
                lostOnce = true; _ = try await base.send(envelope)
                throw CommandError(code: "connection_lost", message: "Reply lost after commit")
            }
        default: break
        }
        var reply = try await base.send(envelope)
        if case .taskDetail(var detail) = reply.result, detail.task.id == "SHOP-31" {
            let at = Date(timeIntervalSince1970: 1_791_100_000)
            let run = RunSummary(id: "review-qa-run", taskId: detail.task.id, stageId: "dev", number: 1, status: .succeeded, requestedModel: "explicit", actualModelName: "Explicit model", countsTowardLimits: true, startedAt: at, endedAt: at.addingTimeInterval(180))
            detail.runs = [run]; detail.clonePath = BoardQA.argument("--qa-review-clone")
            let result = materialChanged ? "Новый результат: изменён алгоритм проверки состояния возврата." : "Объединение по SKU. Гостевая корзина переносится при входе; повторный webhook не создаёт второй платёж."
            detail.artifacts = [
                .init(id: "review-summary", taskId: detail.task.id, runId: run.id, stageId: "dev", kind: "summary", text: mode == "long" ? String(repeating: result + " 👋\n", count: 2500) : result, createdAt: at),
                .init(id: "review-test", taskId: detail.task.id, stageId: "test", kind: "summary", text: "Критерии приёмки проверены. Добавлено 11 тестов.", createdAt: at),
                .init(id: "review-ai", taskId: detail.task.id, stageId: "ai-review", kind: "summary", text: "Замечаний нет; предложено вынести константу.", createdAt: at),
                .init(id: "review-gates", taskId: detail.task.id, runId: run.id, stageId: "dev", kind: "gate_output", text: "swift build\nBUILD SUCCEEDED\nswift test\n11 tests passed", createdAt: at),
                .init(id: "review-files", taskId: detail.task.id, stageId: "dev", kind: "diffstat", text: mode == "unknown" ? "Future format: complete original material" : " Sources/Cart/CartMerge.swift | 80 +++++---\n Sources/Cart/Session.swift | 30 +++\n Tests/CartTests/MergeTests.swift | 58 ++++++\n 3 files changed, 128 insertions(+), 40 deletions(-)\n", createdAt: at),
                .init(id: "review-commits", taskId: detail.task.id, stageId: "dev", kind: "commits", text: String(repeating: "a", count: 40) + " Make cart merge idempotent\n" + String(repeating: "b", count: 40) + " Test repeated delivery\n", createdAt: at)
            ]
            if mode == "empty" { detail.artifacts = []; detail.clonePath = nil; detail.runs = [] }
            if mode == "unknown" { detail.artifacts.append(.init(id: "future", taskId: detail.task.id, kind: "future_review_material", text: "Полный текст неизвестного материала 👋", createdAt: at)) }
            reply.result = .taskDetail(detail)
        }
        return reply
    }
}

extension BoardQA {
    static var reviewClient: QAHumanReviewClient?
    static func prepareReview(_ store: BoardStore) async throws -> Bool {
        guard let mode = argument("--qa-review") else { return false }
        await store.select("SHOP-31"); store.detailTab = "Сводка"
        if ["changes", "stale", "error", "pending", "offline", "long-comment"].contains(mode) {
            store.humanReview.edit("SHOP-31", comments: mode == "long-comment" ? String(repeating: "Проверь состояние возврата. Сохрани результат проверки. 👋\n", count: 100) : "Проверь повторную доставку: второй платёж не должен создаваться.")
            store.beginReview(.requestChanges, task: "SHOP-31")
        }
        if ["reject", "keep", "reject-return"].contains(mode) {
            store.humanReview.edit("SHOP-31", cancel: mode != "reject-return", keepBranch: mode == "keep")
            store.beginReview(.reject, task: "SHOP-31")
        }
        if ["pending", "stale", "error"].contains(mode) { _ = await store.humanReview.submit(.requestChanges, for: "SHOP-31") }
        if mode == "offline" {
            reviewClient?.disconnect(lastSeq: store.projection?.stateSeq)
            try await waitUntil("review disconnected") { !store.canSend }
        }
        if mode == "pipeline-issues" { store.openPipelineIssues("shop") }
        return true
    }
    static func reviewSmoke(_ store: BoardStore) async throws -> [String] {
        guard let client = reviewClient, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Review WindowGroup missing") }
        if argument("--qa-size") == "minimum" { window.setContentSize(.init(width: 1040, height: 640)) }
        await store.select("SHOP-31"); store.detailTab = "Сводка"
        guard store.humanReview.currentContext(for: "SHOP-31")?.targets.map(\.id) == ["dev", "test"] else { throw failure("Review target filter includes read-only or missing coding stages") }
        store.beginReview(.requestChanges, task: "SHOP-31")
        try await waitUntil("native review sheet") { window.attachedSheet != nil }
        try await Task.sleep(for: .milliseconds(300))
        func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        guard let sheet = window.attachedSheet, let editor = sheet.contentView.flatMap({ editors($0).first { !$0.isFieldEditor && $0.isEditable } }) else { throw failure("Native review comment editor missing") }
        let text = "Check status first  \r\n👋"
        sheet.makeFirstResponder(editor); editor.string = text; editor.didChangeText()
        try await waitUntil("native review exact comment") { store.humanReview.draft(for: "SHOP-31")?.comments == text }
        guard !store.canApproveSelected else { throw failure("Cmd-Return can approve behind a comment sheet") }
        client.mode = "stale"; _ = await store.humanReview.submit(.requestChanges, for: "SHOP-31")
        guard store.humanReview.isStale("SHOP-31"), store.humanReview.draft(for: "SHOP-31")?.comments == text, store.error == nil else { throw failure("Stale decision lost text or used modal error") }
        store.reviewRoute = nil
        try await waitUntil("comment sheet closed") { window.attachedSheet == nil }
        store.humanReview.useCurrentReview("SHOP-31")
        guard store.canApproveSelected else { throw failure("Updated review cannot approve") }
        client.mode = "pending"; window.makeKeyAndOrderFront(nil); NSApp.activate(); NSApp.mainMenu?.update()
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36), NSApp.mainMenu?.performKeyEquivalent(with: key) == true else { throw failure("Native Cmd-Return review route missing") }
        try await waitUntil("review awaiting correlated event") { store.humanReview.receipt(for: "SHOP-31")?.phase == .awaitingEvent }
        guard store.projection?.tasks["SHOP-31"]?.state == .waitingHuman(.review), !store.canApproveSelected else { throw failure("OK optimistically completes review") }
        let count = client.sent.count
        _ = await store.humanReview.submit(.reject, for: "SHOP-31")
        guard client.sent.count == count, let envelope = store.humanReview.receipt(for: "SHOP-31")?.envelope else { throw failure("Double decision was sent") }
        // Complete the same acknowledged envelope, then consume the normal mock events.
        client.mode = "summary"; _ = try await client.base.send(envelope)
        try await waitUntil("review confirmed merge queue") { store.projection?.tasks["SHOP-31"]?.stageId == "merge" && store.humanReview.receipt(for: "SHOP-31")?.phase == .applied }
        guard store.projection?.tasks["SHOP-31"]?.state == .queued(nil) else { throw failure("Approve skipped merge queue") }
        await store.select("KBN-10")
        store.humanReview.edit("KBN-10", comments: text, target: "test")
        client.mode = "lost"
        _ = await store.humanReview.submit(.requestChanges, for: "KBN-10")
        try await waitUntil("lost review reply reconciled") { store.humanReview.receipt(for: "KBN-10")?.phase == .applied && store.canSend }
        await store.session.retryDetail()
        try await waitUntil("current returned review detail") { store.session.detailReadState == .loaded && store.detail?.task == store.projection?.tasks["KBN-10"] }
        let changes = client.sent.filter { if case .requestChanges("KBN-10", _, _) = $0.command { true } else { false } }
        guard !changes.isEmpty, Set(changes.map(\.commandId)).count == 1,
              changes.allSatisfy({ $0.command == .requestChanges(taskId: "KBN-10", comments: text, target: "test") }),
              store.detail?.task.stageId == "test", store.detail?.feed.filter({ $0.kind == "review_comment" && $0.text == text }).count == 1 else { throw failure("Lost return reply duplicated or retargeted the decision") }
        await store.select(nil); await store.select("KBN-10")
        guard store.detail?.feed.filter({ $0.kind == "review_comment" && $0.text == text }).count == 1 else { throw failure("Reopen lost review comment") }
        store.detailTab = "Лента"
        if argument("--export-live-window") != nil { try await captureWindow() }
        return ["real WindowGroup native comment editor retains exact CRLF/Unicode", "stale refusal refreshes result and retains comment inline", "coding target follows on_success and excludes read-only stages", "Cmd-Return unavailable behind decision sheet; current review uses approve", "OK remains pending; double decision does not send a new envelope", "correlated update enters merge queue, never local Done", "lost return receipt reconciles exact commandId/comment/explicit target once; reopen retains feed"]
    }
    static func reviewLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = argument("--review-live-fixture"), path.hasPrefix("/tmp/kaban-fe11-"),
              let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String],
              metadata["database"] == argument("--developer-database"), let origin = metadata["origin"], origin.hasPrefix("/tmp/kaban-fe11-") else { throw failure("Private review fixture missing") }
        func id(_ name: String) throws -> TaskID { guard let value = metadata[name] else { throw failure("Fixture task missing: " + name) }; return TaskID(rawValue: value) }
        func git(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", origin] + arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = "Check the current status first.  \r\nKeep the result 👋"
        if argument("--qa-size") == "minimum" { NSApp.windows.first { $0.styleMask.contains(.titled) }?.setContentSize(.init(width: 1040, height: 640)) }
        let approve = try id("approve"), changes = try id("changes"), returned = try id("reject-stage"), kept = try id("reject-keep"), deleted = try id("reject-delete"), stale = try id("stale")
        if CommandLine.arguments.contains("--review-live-reopen") {
            for (task, stage, state) in [(approve, StageID(rawValue: "merge"), TaskState.queued(nil)), (changes, StageID(rawValue: "dev"), .queued(nil)), (returned, StageID(rawValue: "dev"), .queued(nil)), (kept, StageID(rawValue: "review"), .cancelled), (deleted, StageID(rawValue: "review"), .cancelled)] {
                await store.select(task)
                guard store.detail?.task.stageId == stage, store.detail?.task.state == state else { throw failure("Review decision lost after restart") }
                if task == changes { guard store.detail?.feed.filter({ $0.kind == "review_comment" && $0.text == text }).count == 1 else { throw failure("Durable return comment missing after retention") } }
            }
            guard try git(["rev-parse", "refs/kaban/archive/" + kept.rawValue]).1 == metadata["reject-keepCommit"],
                  try git(["show-ref", "--verify", "refs/kaban/archive/" + deleted.rawValue]).0 != 0,
                  try git(["rev-parse", "refs/heads/main"]).1 == metadata["main"] else { throw failure("Archived result or main changed after restart") }
            await store.select(changes); store.detailTab = "Лента"
            if argument("--export-live-window") != nil { try await captureWindow() }
            return ["private daemon restarted after journal deletion", "approve remains queued for merge; both returns remain queued at explicit dev", "exact comment remains once in durable getTaskDetail feed", "keepBranch archive retains actual result commit; deleted branch absent; main unchanged"]
        }
        await store.select(approve)
        guard let detail = store.detail, detail.task.state == .waitingHuman(.review), detail.clonePath == metadata["approveClone"],
              Set(detail.artifacts.map(\.kind)).isSuperset(of: ["summary", "commits", "diffstat", "gate_output"]),
              detail.artifacts.filter({ $0.kind == "commits" }).contains(where: { $0.text.contains(metadata["approveCommit"] ?? "missing") }),
              detail.artifacts.filter({ $0.kind == "diffstat" }).contains(where: { ReviewMaterialPresentation.files($0.text)?.first?.path == "result.txt" }),
              detail.artifacts.filter({ $0.kind == "gate_output" }).contains(where: { $0.text.contains("Private review gate passed") }) else { throw failure("Actual review materials missing") }
        if CommandLine.arguments.contains("--review-live-open-cursor") {
            guard await store.openClone(detail.clonePath) else { throw failure("NSWorkspace did not open actual clone in Cursor") }
        }
        if let before = argument("--review-live-before") {
            store.detailTab = "Сводка"
            try await Task.sleep(for: .milliseconds(500))
            let bitmap = try await ReferenceExport.captureLiveWindow()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("Review before PNG missing") }
            try data.write(to: URL(fileURLWithPath: before))
        }
        for (task, decision) in [(approve, HumanReviewDecision.approve), (changes, .requestChanges), (returned, .reject), (kept, .reject), (deleted, .reject)] {
            await store.select(task)
            let bounce = store.detail?.task.bounceByReason
            if decision == .requestChanges { store.humanReview.edit(task, comments: text, target: "dev") }
            if decision == .reject { store.humanReview.edit(task, target: "dev", cancel: task != returned, keepBranch: task == kept) }
            try await waitUntil("live review decision ready") { store.humanReview.canSubmit(decision, for: task) }
            guard await store.humanReview.submit(decision, for: task) else { throw failure("Live review decision rejected") }
            try await waitUntil("live correlated review decision") { store.humanReview.receipt(for: task)?.phase == .applied }
            await store.session.retryDetail()
            try await waitUntil("current live decision detail") {
                store.session.detailReadState == .loaded && store.detail?.task == store.projection?.tasks[task] &&
                (store.detail?.seq ?? -1) >= (store.humanReview.receipt(for: task)?.confirmedSeq ?? 0)
            }
            guard store.detail?.task.bounceByReason == bounce else { throw failure("Human return increased bounce count") }
            if task == approve { guard store.detail?.task.stageId == "merge", store.detail?.task.state == .queued(nil) else { throw failure("Live approve skipped merge queue") } }
            else if task == changes || task == returned {
                guard store.detail?.task.stageId == "dev", store.detail?.task.state == .queued(nil), store.detail?.task.runsSinceHuman == 0 else { throw failure("Live return target or counters wrong") }
                if task == changes { guard store.detail?.feed.filter({ $0.kind == "review_comment" && $0.text == text }).count == 1 else { throw failure("Return comment missing") } }
            } else { guard store.detail?.task.state == .cancelled else { throw failure("Live reject did not cancel") } }
        }
        try await waitUntil("real clone cleanup") {
            !FileManager.default.fileExists(atPath: metadata["reject-keepClone"] ?? "") && !FileManager.default.fileExists(atPath: metadata["reject-deleteClone"] ?? "")
        }
        guard try git(["rev-parse", "refs/kaban/archive/" + kept.rawValue]).1 == metadata["reject-keepCommit"],
              try git(["show", "refs/kaban/archive/" + kept.rawValue + ":result.txt"]).1.contains("Actual result for reject-keep"),
              try git(["show-ref", "--verify", "refs/kaban/archive/" + deleted.rawValue]).0 != 0,
              try git(["rev-parse", "refs/heads/main"]).1 == metadata["main"] else { throw failure("keepBranch did not preserve actual result or changed main") }
        await store.select(stale); store.humanReview.edit(stale, comments: "Preserve stale comment")
        guard await store.send(.approve(taskId: stale), taskID: stale) else { throw failure("External review decision failed") }
        try await waitUntil("stale task moved") { store.projection?.tasks[stale]?.stageId == "merge" && store.session.pending(in: .task(stale)) == nil }
        let rejected = await store.session.send(.requestChanges(taskId: stale, comments: "Old review decision", target: "dev"), editor: true)
        guard !rejected, store.error == nil, store.humanReview.draft(for: stale)?.comments == "Preserve stale comment" else { throw failure("Live invalid_state lost draft") }
        await store.session.retryDetail()
        try await waitUntil("current refused decision detail") { store.session.detailReadState == .loaded && store.detail?.task == store.projection?.tasks[stale] }
        guard store.detail?.task.stageId == "merge", store.detail?.feed.contains(where: { $0.text == "Old review decision" }) == false else { throw failure("Refused decision changed details") }
        await store.select(changes); store.detailTab = "Лента"
        if argument("--export-live-window") != nil { try await captureWindow() }
        return ["real bundled daemon over private stdio and real git/gates/materials", "actual clone opened with NSWorkspace when requested; no Cursor CLI run", "approve queues merge after correlated event", "explicit requestChanges and reject-stage queue dev without bounce increment", "reject cancel cleans clones; keepBranch archives actual result commit and file; no-keep leaves no archive; main unchanged", "real invalid_state refresh preserves comment and adds no refused decision to durable feed"]
    }
}
