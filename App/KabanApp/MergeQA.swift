#if KABAN_QA
import AppKit
import KabanProtocol
import KabanBoardCore

/// Explicit material fixtures only; actions still use typed mock commands/events.
@MainActor final class QAMergeClient: KabanClient {
    let base: MockKabanClient
    let mode: String
    var sent: [CommandEnvelope] = []
    init(base: MockKabanClient, mode: String) { self.base = base; self.mode = mode }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities {
        var value = try await base.capabilities()
        value.commands.removeAll { $0.name == CommandName.recheck.rawValue }
        value.commands.append(.init(name: CommandName.recheck.rawValue, support: .supported, scopes: ["project"]))
        return value
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        if case .recheck = envelope.command {
            sent.append(envelope)
            return .init(commandId: envelope.commandId, seq: nil, result: mode == "pending" ? .ok : .error(.init(code: "project_unavailable", message: "Папка проекта временно недоступна. Ваши правки сохранены.")))
        }
        if case .requestChanges = envelope.command { sent.append(envelope) }
        var reply = try await base.send(envelope)
        if case .taskDetail(var detail) = reply.result, detail.task.id == "SHOP-29" {
            let now = detail.task.updatedAt
            detail.artifacts = [.init(id: "merge-summary", taskId: detail.task.id, stageId: "dev", kind: "summary", text: "Сохранена совместимость индексов и поиск по SKU.", createdAt: now)]
            if ["return", "review", "limit", "changes", "long", "done"].contains(mode) {
                let path = mode == "long" ? String(repeating: "очень-длинный-путь/", count: 14) + "👋.swift" : "Sources/Search/SKUIndex.swift"
                let material = MergeConflictMaterial(files: [path, "Tests/SearchTests/SKUIndexTests.swift"])
                detail.artifacts.append(.init(id: "merge-conflict", taskId: detail.task.id, stageId: "merge", kind: "merge_conflict", text: String(decoding: try KabanCoding.makeEncoder().encode(material), as: UTF8.self), createdAt: now))
            }
            if mode == "done" {
                let result = LocalMergeResult(baseCommit: String(repeating: "a", count: 40), commit: String(repeating: "b", count: 40), ref: "refs/heads/main")
                detail.artifacts.append(.init(id: "merge-result", taskId: detail.task.id, stageId: "merge", kind: "merge_result", text: String(decoding: try KabanCoding.makeEncoder().encode(result), as: UTF8.self), createdAt: now))
            }
            if mode == "unknown" { detail.artifacts.append(.init(id: "merge-future", taskId: detail.task.id, kind: "merge_result", text: "Unknown future format", createdAt: now)) }
            reply.result = .taskDetail(detail)
        }
        return reply
    }
}

extension BoardQA {
    private static func captureMergeBefore(path: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        let bitmap = try await NativeWindowCapture.capture()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("Merge before PNG missing") }
        try data.write(to: URL(fileURLWithPath: path))
        if let sheet = NSApp.windows.first(where: { $0.styleMask.contains(.titled) })?.attachedSheet,
           let view = sheet.contentView?.superview ?? sheet.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".sheet.png"))
        }
    }
    static var mergeClient: QAMergeClient?
    static func prepareMerge(_ store: BoardStore) async throws -> Bool {
        guard let mode = AppArguments.value("--qa-merge") else { return false }
        await store.select("SHOP-29"); store.detailTab = "Сводка"
        if mode == "overlaps" { store.hide("kaban"); store.overlapRoute = .init(task: "SHOP-29") }
        if mode == "changes" {
            store.humanReview.edit("SHOP-29", comments: "Разреши конфликт индекса. Сохрани совместимость поиска по SKU.")
            store.beginReview(.requestChanges, task: "SHOP-29")
        }
        if mode == "error" || mode == "pending" { await store.recheckProject("shop") }
        return true
    }
    static func mergeSmoke(_ store: BoardStore) async throws -> [String] {
        guard let client = mergeClient, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Merge WindowGroup missing") }
        window.setContentSize(.init(width: 1040, height: 640))
        await store.select("SHOP-29")
        guard store.detail?.task.state == .waitingHuman(.conflictLimit), !store.canApproveSelected,
              store.humanReview.currentContext(for: "SHOP-29")?.targets.map(\.id) == ["dev"] else { throw failure("Merge limit allows invalid review decision") }
        store.beginReview(.requestChanges, task: "SHOP-29")
        try await waitUntil("native merge return sheet") { window.attachedSheet != nil }
        try await Task.sleep(for: .milliseconds(300))
        func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        guard let sheet = window.attachedSheet, let editor = sheet.contentView.flatMap({ editors($0).first { !$0.isFieldEditor && $0.isEditable } }) else { throw failure("Merge comment editor missing") }
        let text = "Fix conflict; review again.  \r\n👋"
        sheet.makeFirstResponder(editor); editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
        try await waitUntil("exact merge comment") { store.humanReview.draft(for: "SHOP-29")?.comments == text }
        guard await store.humanReview.submit(.requestChanges, for: "SHOP-29") else { throw failure("Merge return refused") }
        let duplicate = await store.humanReview.submit(.requestChanges, for: "SHOP-29")
        try await waitUntil("correlated merge return") { store.projection?.tasks["SHOP-29"]?.stageId == "dev" && store.humanReview.receipt(for: "SHOP-29")?.phase == .applied }
        let expected = Command.requestChanges(taskId: "SHOP-29", comments: text, target: "dev")
        guard !duplicate, !client.sent.isEmpty, Set(client.sent.map(\.commandId)).count == 1,
              client.sent.allSatisfy({ $0.command == expected }) else { throw failure("Duplicate decision or altered merge return") }
        store.reviewRoute = nil
        try await waitUntil("merge sheet closed") { window.attachedSheet == nil }
        store.hide("kaban"); store.overlapRoute = .init(task: "SHOP-29")
        try await waitUntil("native overlap sheet") { window.attachedSheet != nil }
        await store.openRelatedTask("KBN-15")
        try await waitUntil("hidden related task selected") { store.selectedID == "KBN-15" && store.visibleIDs.contains("kaban") && window.attachedSheet == nil }
        return ["actual minimum WindowGroup and native TextEditor", "merge conflict limit cannot approve", "one exact explicit decision; any reconciliation replays use the same commandId", "correlated dev queue", "native overlap sheet and link reveals hidden project"]
    }
    static func mergeLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = AppArguments.value("--merge-live-fixture"), path.hasPrefix("/tmp/kaban-fe12-"),
              let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String],
              metadata["database"] == AppArguments.value("--developer-database"), let origin = metadata["origin"], origin.hasPrefix("/tmp/kaban-fe12-"),
              let mode = metadata["mode"], let firstRaw = metadata["first"], let projectRaw = metadata["project"] else { throw failure("Private merge fixture missing") }
        let first = TaskID(rawValue: firstRaw), project = ProjectID(rawValue: projectRaw)
        func read(_ id: TaskID) async throws {
            await store.select(id)
            try await waitUntil("current merge details for " + id.rawValue) {
                guard let card = store.projection?.tasks[id], let detail = store.detail else { return false }
                return detail.task == card && store.session.detailReadState == .loaded
            }
        }
        let window = NSApp.windows.first { $0.styleMask.contains(.titled) }
        if AppArguments.value("--qa-size") == "minimum" { window?.setContentSize(.init(width: 1040, height: 640)) }
        func git(_ args: [String]) throws -> String {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", origin] + args; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw failure("Private git read failed") }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await read(first); store.detailTab = "Сводка"
        if mode == "queue" {
            let second = TaskID(rawValue: metadata["second"] ?? "")
            guard store.humanReview.canSubmit(.approve, for: first) else { throw failure("First review unavailable") }
            _ = await store.humanReview.submit(.approve, for: first)
            try await waitUntil("first real merge queue") { store.projection?.tasks[first]?.stageId == "merge" && store.projection?.tasks[first]?.state.status == .queued }
            try await read(second); _ = await store.humanReview.submit(.approve, for: second)
            try await waitUntil("second real merge queue") { store.mergeQueue(project).count == 2 }
            _ = await store.session.send(.setPriority(taskId: second, priority: 99))
            try await waitUntil("second priority confirmed") { store.projection?.tasks[second]?.priority == 99 }
            guard store.mergeQueue(project).map(\.id) == [first, second], try git(["rev-parse", "main"]) == metadata["main"] else { throw failure("Approval changed main or queue order") }
            try await read(first)
            if let board = AppArguments.value("--merge-live-board-before") {
                await store.select(nil); window?.setContentSize(.init(width: 1440, height: 900))
                try await captureMergeBefore(path: board); try await read(first)
            }
            if let before = AppArguments.value("--merge-live-before") { try await captureMergeBefore(path: before) }
            _ = await store.session.send(.resumeAll)
            try await waitUntil("both real local merges") { store.projection?.tasks[first]?.state == .done && store.projection?.tasks[second]?.state == .done }
            try await read(first); guard let firstResult = store.detail.flatMap(MergePresentation.result) else { throw failure("First final commit missing") }
            try await read(second); guard let secondResult = store.detail.flatMap(MergePresentation.result), secondResult.baseCommit == firstResult.commit,
                  secondResult.commit == (try git(["rev-parse", "main"])) else { throw failure("Actual approval order/result not preserved") }
        } else if mode == "dirty" {
            guard store.detail?.task.state == .blocked(.mainDirty), store.mergeQueue(project).count == 2 else { throw failure("Dirty queue missing") }
            await store.recheckProject(project)
            try await waitUntil("real project recheck receipt") { store.recheckRecord(project)?.phase == .applied }
            guard store.projection?.tasks[first]?.state == .blocked(.mainDirty),
                  try git(["diff", "--cached"]) == metadata["staged"], try git(["diff"]) == metadata["unstaged"],
                  try git(["rev-parse", "main"]) == metadata["main"],
                  try String(contentsOfFile: origin + "/shared.txt", encoding: .utf8) == metadata["file"] else { throw failure("UI recheck changed user files/index/main") }
        } else if mode == "conflict" {
            guard store.detail?.task.state == .waitingHuman(.conflictLimit), store.detail?.task.stageId == "merge", !store.canApproveSelected,
                  store.detail?.artifacts.contains(where: { MergePresentation.conflict($0)?.files == ["shared.txt"] }) == true else { throw failure("Durable limit/conflict paths missing") }
            store.humanReview.edit(first, comments: "Resolve shared.txt conflict. Review again."); store.beginReview(.requestChanges, task: first)
            try await waitUntil("real merge return sheet") { window?.attachedSheet != nil }
            if let before = AppArguments.value("--merge-live-before") { try await captureMergeBefore(path: before) }
            _ = await store.humanReview.submit(.requestChanges, for: first)
            try await waitUntil("real manual return") { store.humanReview.receipt(for: first)?.phase == .applied && store.projection?.tasks[first]?.stageId == "dev" }
            store.reviewRoute = nil; await store.session.retryDetail()
            guard store.detail?.feed.contains(where: { $0.kind == "review_comment" && $0.text == "Resolve shared.txt conflict. Review again." }) == true,
                  try git(["rev-parse", "main"]) == metadata["main"] else { throw failure("Return lost comment or changed main") }
        } else if mode == "review" {
            guard store.detail?.task.state == .waitingHuman(.review), store.detail?.task.bounceByReason["merge_conflict"] == 1,
                  store.detail?.artifacts.contains(where: { $0.kind == "merge_conflict" }) == true else { throw failure("Repeated Human Review missing") }
            if let before = AppArguments.value("--merge-live-before") { try await captureMergeBefore(path: before) }
            _ = await store.humanReview.submit(.approve, for: first)
            try await waitUntil("fixed result queued") { store.projection?.tasks[first]?.stageId == "merge" }
            _ = await store.session.send(.resumeAll)
            try await waitUntil("fixed result merged") { store.projection?.tasks[first]?.state == .done }
            try await read(first)
            guard store.detail.flatMap(MergePresentation.result)?.commit == (try git(["rev-parse", "main"])) else { throw failure("Fixed result commit missing") }
        } else if mode == "recovery" {
            try await waitUntil("startup merge reconciliation") { store.projection?.tasks[first]?.state == .done }
            try await read(first)
            guard store.detail.flatMap(MergePresentation.result)?.commit == metadata["main"],
                  try git(["rev-parse", "main"]) == metadata["main"], try git(["rev-list", "--count", "main"]) == metadata["commits"],
                  store.humanReview.record(for: first)?.submittedBy == nil else { throw failure("Recovery repeated git or required UI decision") }
        } else if mode == "gates" {
            guard store.detail?.task.stageId == "dev", store.detail?.task.bounceByReason["merge_conflict"] == 1,
                  store.detail?.artifacts.contains(where: { $0.kind == "merge_gate_output" && $0.text.contains("/usr/bin/false") }) == true else { throw failure("Merge gate return materials missing") }
        }
        try await Task.sleep(for: .milliseconds(450))
        return ["actual private stdio daemon and WindowGroup", "production git/gates scenario: " + mode, "durable merge facts after journal retention", "source states, no UI merge automaton", "local main verified"]
    }
}
#endif
