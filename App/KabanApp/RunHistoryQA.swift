import AppKit
import KabanProtocol
import KabanBoardCore

/// Explicit log/history QA only. It never replaces the production source.
@MainActor final class QARunHistoryClient: KabanClient {
    let detail: QADetailClient
    var mode: String
    var logReads = 0
    var tailStarts: [RunID] = []
    var tailStops: [RunID] = []
    var restoreEnvelope: CommandEnvelope?
    var extraRecords = 0
    private var cachedVolume: [AgentEvent]?
    private var continuation: AsyncThrowingStream<KabanClientUpdate, Error>.Continuation?
    init(base: MockKabanClient, mode: String) { detail = .init(base: base, mode: "summary"); self.mode = mode }
    func getSnapshot() async throws -> Snapshot { try await detail.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await detail.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> {
        let updates = detail.updates()
        return AsyncThrowingStream { sink in
            continuation = sink
            let forward = Task {
                do { for try await value in updates { sink.yield(value) } }
                catch { sink.finish(throwing: error) }
            }
            sink.onTermination = { @Sendable _ in forward.cancel() }
        }
    }
    func events() -> AsyncStream<EventEnvelope> { detail.events() }
    func capabilities() async throws -> DaemonCapabilities {
        var value = try await detail.capabilities()
        value.commands.removeAll { $0.name == CommandName.restoreWIP.rawValue }
        value.commands.append(.init(name: CommandName.restoreWIP.rawValue, support: .supported))
        return value
    }
    func history(_ task: TaskID) -> [RunSummary] {
        let at = Date(timeIntervalSince1970: 1_791_375_000)
        return [
            .init(id: "qa-log-live", taskId: task, stageId: "dev", number: 3, status: .running, requestedModel: "composer-1", actualModelName: nil, countsTowardLimits: true, startedAt: at, logPath: "/private/qa/logs/run-3.jsonl"),
            .init(id: "qa-log-wip", taskId: task, stageId: "dev", number: 2, status: .killed, endReason: .pausedByHuman, requestedModel: "composer-1", actualModelName: "Composer", countsTowardLimits: false, startedAt: at.addingTimeInterval(-600), endedAt: at.addingTimeInterval(-500), exitCode: 130, logPath: "/private/qa/logs/run-2.jsonl", wipRef: mode == "wip-long" ? "refs/kaban/wip/" + String(repeating: "long-unicode-reference-", count: 80) : "refs/kaban/wip/SHOP-31/qa-log-wip"),
            .init(id: "qa-log-old", taskId: task, stageId: "test", number: 1, status: .failed, endReason: .gateFailed, requestedModel: "provider/model-with-a-long-name", countsTowardLimits: true, startedAt: at.addingTimeInterval(-1000), endedAt: at.addingTimeInterval(-900), exitCode: 1)
        ]
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        switch envelope.command {
        case .getRunHistory(let id): return .init(commandId: envelope.commandId, seq: nil, result: .runs(history(id)))
        case .restoreWIP(let task, let run, let ref):
            guard history(task).contains(where: { $0.id == run && $0.wipRef == ref }) else {
                return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: "stale_wip_ref", message: "WIP изменился.")))
            }
            restoreEnvelope = envelope
            return .init(commandId: envelope.commandId, seq: nil, result: .ok)
        default:
            var reply = try await detail.send(envelope)
            if case .taskDetail(var value) = reply.result { value.runs = history(value.task.id); reply.result = .taskDetail(value) }
            return reply
        }
    }
    func confirmRestore(seq: Seq) {
        guard let envelope = restoreEnvelope, case .restoreWIP(let task, let run, let ref) = envelope.command else { return }
        continuation?.yield(.event(.init(seq: seq, at: Date(), projectId: "shop", commandId: envelope.commandId,
                                         event: .wipRestored(.init(taskId: task, runId: run, wipRef: ref)))))
    }
    func records() async -> [AgentEvent] {
        if mode == "empty" { return [] }
        if mode == "volume" || mode == "volume-live" {
            let count = 16_000 + extraRecords
            if cachedVolume?.count != count {
                cachedVolume = await Task.detached { (0..<count).map { AgentEvent.message(role: "assistant", text: "Запись \($0) · Проверяем сохранность результата при повторной доставке. Привет 👋") } }.value
            }
            return cachedVolume ?? []
        }
        return [
            .initialized(modelName: nil, sessionId: "qa-session"),
            .message(role: "assistant", text: "Проверяю повторную доставку вебхуков и возвраты. Результат сохранится в истории задачи."),
            .toolCall(id: "read-file", name: "read_file", summary: "Refund.swift\nПолное содержимое инструмента\nСтрока для поиска: QA_TOOL_DETAIL"),
            .toolResult(id: "read-file", ok: true, summary: "Получено 48 строк\nQA_TOOL_RESULT\nКонец инструмента"),
            .usage(inputTokens: 480, outputTokens: nil),
            .message(role: "assistant", text: String(repeating: "Большой исходный текст 👋\n", count: 12_000)),
            .error(code: "gate_failed", message: "Проверка повтора завершилась ошибкой. Подробности сохранены в результате инструмента."),
            .result(ok: false, durationMs: nil)
        ]
    }
    func readLog(runId: RunID, fromOffset: Int64, limit: Int) async throws -> LogPage {
        logReads += 1
        if mode == "loading" { try await Task.sleep(for: .seconds(120)) }
        if mode == "missing" { throw CommandError(code: "log_unavailable", message: "Файл лога удалён или недоступен. История запуска сохранена.") }
        if mode == "expired", fromOffset < 200 { throw CommandError(code: "log_offset_expired", message: "Начало лога удалено.", params: ["availableFromOffset": "200"]) }
        let values = await records()
        let start: Int64 = mode == "expired" ? 200 : 0
        let end = start + Int64(values.count)
        guard fromOffset >= start, fromOffset <= end else { throw CommandError(code: "invalid_request", message: "Смещение за пределами лога.") }
        let index = Int(fromOffset - start), count = min(limit, values.count - index)
        return .init(batch: .init(runId: runId, fromOffset: fromOffset, nextOffset: fromOffset + Int64(count),
                                  events: Array(values[index..<(index + count)])),
                     availableFromOffset: start, endOffset: end, isComplete: mode != "live" && mode != "volume-live")
    }
    func tailLog(runId: RunID, fromOffset: Int64) -> AsyncThrowingStream<LogBatch, Error> {
        tailStarts.append(runId)
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(2)) { sink in
            let forward = Task {
                var cursor = fromOffset
                do {
                    repeat {
                        let page = try await readLog(runId: runId, fromOffset: cursor, limit: DaemonWire.maxPageSize)
                        if !page.batch.events.isEmpty {
                            switch sink.yield(page.batch) {
                            case .enqueued: cursor = page.batch.nextOffset
                            default: throw CommandError(code: "log_stream_overflow", message: "Поток переполнен. Повторите чтение.")
                            }
                        }
                        if page.isComplete && cursor == page.endOffset { sink.finish(); return }
                        try await Task.sleep(for: .milliseconds(mode.hasPrefix("volume") ? 10 : 200))
                    } while !Task.isCancelled
                } catch { sink.finish(throwing: error) }
            }
            sink.onTermination = { @Sendable [weak self] _ in
                forward.cancel()
                Task { @MainActor in self?.tailStops.append(runId) }
            }
        }
    }
}
extension BoardQA {
    static var logClient: QARunHistoryClient?
    static func prepareRunHistory(_ store: BoardStore) async throws -> Bool {
        guard let mode = argument("--qa-log") else { return false }
        await store.select("SHOP-31"); await store.session.readRunHistory(); store.detailTab = "Запуски"
        guard let run = store.session.runHistory?.first else { throw failure("QA run history missing") }
        if mode == "history" { return true }
        if mode == "wip" || mode == "wip-long", let wip = store.session.runHistory?.first(where: { $0.wipRef != nil }) { store.beginWIPRestore(wip) }
        else { store.logRunRoute = run }
        return true
    }
    static func logVolumeSmoke(_ store: BoardStore) async throws -> [String] {
        guard let client = logClient, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Volume window missing") }
        var maximumGap = 0.0
        let ticker = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous); previous = now
            }
        }
        defer { ticker.cancel() }
        await store.select("SHOP-31"); await store.session.readRunHistory()
        guard let run = store.session.runHistory?.first else { throw failure("Volume run missing") }
        store.logRunRoute = run
        func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        func textView() -> NSTextView? { window.attachedSheet?.contentView.flatMap { textViews($0).first } }
        for _ in 0..<1_500 {
            if store.runLog.nextOffset == 16_000, textView()?.string.contains("Запись 15999") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard store.runLog.nextOffset == 16_000, let text = textView(), text.string.contains("Запись 15999"),
              store.runLog.entries.first!.offset > 0,
              store.runLog.residentLines <= 50_000, store.runLog.residentBytes <= 8 * 1024 * 1024 else { throw failure("Volume completion/bounds missing: cursor=\(store.runLog.nextOffset), state=\(store.runLog.state), loaded=\(store.runLog.entries.count), text=\(textView()?.string.utf8.count ?? 0)") }
        let reading = (text.string as NSString).range(of: "Запись 10000")
        text.scrollRangeToVisible(reading)
        try await Task.sleep(for: .milliseconds(150))
        guard let scroll = text.enclosingScrollView else { throw failure("Volume scroll missing") }
        text.setSelectedRange(reading)
        let beforeY = text.firstRect(forCharacterRange: reading, actualRange: nil).minY
        client.mode = "volume-live"; client.extraRecords = 100; await store.runLog.retry()
        try await waitUntil("appended volume") { store.runLog.nextOffset == 16_100 && text.string.contains("Запись 16099") }
        try await Task.sleep(for: .milliseconds(150))
        let after = (text.string as NSString).range(of: "Запись 10000")
        let afterY = text.firstRect(forCharacterRange: after, actualRange: nil).minY
        guard abs(afterY - beforeY) < 8, scroll.contentView.bounds.maxY < text.bounds.maxY - 24 else { throw failure("New output moved the reading anchor: before=\(beforeY), after=\(afterY), clip=\(scroll.contentView.bounds), text=\(text.bounds), first=\(store.runLog.entries.first!.offset)") }
        text.copy(nil)
        guard NSPasteboard.general.string(forType: .string) == "Запись 10000" else { throw failure("Selection lost during prefix eviction") }
        let data = try await store.runLog.exportLoadedRecords()
        guard !data.isEmpty else { throw failure("Loaded export missing") }
        store.logRunRoute = nil; store.runLog.close()
        try await waitUntil("volume tail closed") { window.attachedSheet == nil }
        guard maximumGap < 0.5 else { throw failure("Native UI heartbeat stalled for \(maximumGap) seconds") }
        return ["16000 normalized records through actual TextKit2", "resident bounds <=50000 lines and 8MiB; stable daemon offsets after eviction", "100 appended records preserve reading anchor and selection without autoscroll", "normalized loaded-fragment export", "native main-actor heartbeat maximum gap \(maximumGap) seconds"]
    }
    static func logSmoke(_ store: BoardStore) async throws -> [String] {
        guard let client = logClient, let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Log WindowGroup missing") }
        await store.select("SHOP-31"); await store.session.readRunHistory(); store.detailTab = "Запуски"
        guard let run = store.session.runHistory?.first else { throw failure("Run history missing") }
        store.logRunRoute = run
        func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        func textView() -> NSTextView? { window.attachedSheet?.contentView.flatMap { textViews($0).first } }
        try await waitUntil("structured log") { textView()?.string.contains("read_file") == true }
        guard let text = textView(), !text.isEditable, text.usesFindBar, text.textLayoutManager != nil,
              !text.string.contains("QA_TOOL_DETAIL"), store.runLog.entries.contains(where: \.requiresSeparateRead) else { throw failure("Readonly TextKit2/collapse/large source missing") }
        let links = text.textStorage
        var tool: (Any, Int)?
        links?.enumerateAttribute(.link, in: NSRange(location: 0, length: links?.length ?? 0)) { value, range, stop in
            if let value, String(describing: value).hasPrefix("kaban-log-tool") { tool = (value, range.location); stop.pointee = true }
        }
        guard let tool else { throw failure("Tool link missing") }
        _ = text.delegate?.textView?(text, clickedOnLink: tool.0, at: tool.1)
        try await waitUntil("expanded output") { textView()?.string.contains("QA_TOOL_DETAIL") == true }
        store.find()
        try await waitUntil("native find bar") { text.enclosingScrollView?.isFindBarVisible == true }
        let range = (text.string as NSString).range(of: "QA_TOOL_DETAIL"); text.setSelectedRange(range); text.copy(nil)
        guard NSPasteboard.general.string(forType: .string) == "QA_TOOL_DETAIL" else { throw failure("Native copy missing") }
        // Source is re-read through the same client; the resident cache remains bounded.
        let large = try await store.runLog.readFullRecord(at: 5)
        guard case .message(_, let full) = large, full.contains("👋"), full.utf8.count > 256 * 1024 else { throw failure("Full log source missing") }
        var sourceLink: (Any, Int)?
        text.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: text.textStorage?.length ?? 0)) { value, range, stop in
            if let value, String(describing: value).hasPrefix("kaban-log-source") { sourceLink = (value, range.location); stop.pointee = true }
        }
        guard let sourceLink else { throw failure("Separate source link missing") }
        _ = text.delegate?.textView?(text, clickedOnLink: sourceLink.0, at: sourceLink.1)
        let encoder = KabanCoding.makeEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let exactSource = String(decoding: try encoder.encode(large), as: UTF8.self)
        try await waitUntil("full source native text") {
            window.attachedSheet?.attachedSheet?.contentView.flatMap { textViews($0).first }?.string == exactSource
        }
        guard let sourceSheet = window.attachedSheet?.attachedSheet, let sourceText = sourceSheet.contentView.flatMap({ textViews($0).first }),
              sourceText.textLayoutManager != nil, !sourceText.isEditable, !store.runLog.isVisible else { throw failure("Source reader/lifecycle missing") }
        store.find()
        try await waitUntil("source find bar") { sourceText.enclosingScrollView?.isFindBarVisible == true }
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sourceSheet.windowNumber,
                                           context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53),
              sourceSheet.performKeyEquivalent(with: escape) else { throw failure("Source Escape missing") }
        try await waitUntil("source sheet closed; log resumed") { window.attachedSheet?.attachedSheet == nil && store.runLog.isVisible }
        client.mode = "live"; await store.runLog.select(run.id)
        try await waitUntil("tail started") { store.runLog.isTailing }
        let next = client.history(run.taskId)[1]; await store.runLog.select(next.id)
        try await waitUntil("previous tail cancelled") { client.tailStops.contains(run.id) }
        guard store.runLog.runID == next.id else { throw failure("Run selection wrong") }
        store.logRunRoute = nil; store.runLog.close()
        try await waitUntil("log sheet closed") { window.attachedSheet == nil }
        client.mode = "summary"
        let wip = next
        store.beginWIPRestore(wip)
        try await waitUntil("WIP confirmation") { window.attachedSheet != nil }
        let card = store.projection?.tasks[wip.taskId]
        guard let route = store.wipRestoreRoute,
              let command = route.request.command(current: card, history: store.history(for: wip.taskId), pipeline: store.projection?.pipelines[card!.projectId]),
              await store.send(command, taskID: wip.taskId) else { throw failure("Exact WIP command missing") }
        guard store.restoreRecord(for: wip.taskId)?.phase == .awaitingEffect, store.projection?.tasks[wip.taskId] == card else { throw failure("OK prematurely changed task/completed restore") }
        client.confirmRestore(seq: (store.projection?.stateSeq ?? 0) + 1)
        try await waitUntil("correlated WIP result") { store.restoreRecord(for: wip.taskId)?.phase == .applied }
        store.wipRestoreRoute = nil
        try await waitUntil("WIP sheet closed") { window.attachedSheet == nil }
        await store.select(nil)
        return ["native WindowGroup readonly TextKit2 and find bar", "tool output expands with full Unicode source and native copy", "oversized records use separate exact read and chunked native TextKit2 source; foreground find and Escape", "old tail cancelled on run change and modal close", "exact WIP confirmation; OK remains awaitingEffect without local card mutation", "correlated WIP event confirms outcome through BoardSession"]
    }
}

extension BoardQA {
    static func logLiveSmoke(_ store: BoardStore) async throws -> [String] {
        guard let path = argument("--log-live-fixture"), path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
              let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String],
              let taskValue = metadata["task"], let runValue = metadata["run"], let ref = metadata["wip"],
              let clone = metadata["clone"], let origin = metadata["origin"], let historyPath = metadata["history"] else { throw failure("Isolated live run fixture missing") }
        let taskID = TaskID(rawValue: taskValue), runID = RunID(rawValue: runValue)
        await store.select(taskID); await store.session.readRunHistory(); store.detailTab = "Запуски"
        let original = try KabanCoding.makeDecoder().decode([RunSummary].self, from: Data(contentsOf: URL(fileURLWithPath: historyPath)))
        guard store.history(for: taskID) == original, let run = original.first(where: { $0.id == runID }) else { throw failure("Real daemon history changed") }
        store.logRunRoute = run
        if argument("--log-live-missing") != nil {
            try await waitUntil("missing real log") {
                if case .unavailable(let error) = store.runLog.state { return error.code == CommandError.logUnavailableCode }
                return false
            }
            if argument("--export-live-window") != nil { try await captureWindow() }
            return ["bundled daemon distinguishes removed log file from empty log and preserves RunSummary"]
        }
        try await waitUntil("real retained log prefix") { store.runLog.state == .expired(availableFromOffset: 76) }
        await store.runLog.readAvailablePrefix()
        do {
            try await waitUntil("retained log complete") { store.runLog.nextOffset == 1100 && !store.runLog.isTailing }
        } catch {
            throw failure("Retained read failed: cursor=\(store.runLog.nextOffset), visible=\(store.runLog.isVisible), tail=\(store.runLog.isTailing), state=\(store.runLog.state)")
        }
        let data = try await store.runLog.exportLoadedRecords()
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("<redacted>"), !text.contains(metadata["secret"] ?? "never-match"),
              store.runLog.entries.first?.offset == 76 else { throw failure("Cleaned normalized export/prefix missing") }
        if argument("--export-live-window") != nil { try await captureWindow() }
        store.logRunRoute = nil; store.runLog.close()
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { throw failure("Live WindowGroup missing") }
        try await waitUntil("live log sheet closed") { window.attachedSheet == nil }
        if argument("--log-live-reopen") == nil {
            store.beginWIPRestore(run)
            try await waitUntil("live WIP confirmation") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet,
                  let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                  sheet.performKeyEquivalent(with: enter) else { throw failure("WIP default native action missing") }
            try await waitUntil("real correlated WIP restore") {
                store.restoreRecord(for: taskID)?.phase == .applied && store.detail?.wipRestoreOperations?.contains { $0.runId == runID && $0.wipRef == ref && $0.status == .succeeded } == true
            }
            await store.session.readRunHistory()
            guard store.history(for: taskID) == original, store.projection?.tasks[taskID]?.state == .paused else { throw failure("Restore rewrote history/card state") }
        } else {
            guard store.detail?.wipRestoreOperations?.contains(where: { $0.runId == runID && $0.wipRef == ref && $0.status == .succeeded }) == true else { throw failure("Restore result missing after daemon restart") }
        }
        func gitRead(_ repo: String, _ arguments: [String]) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo] + arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw failure("Read-only git verification failed") }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard try String(contentsOfFile: clone + "/draft.txt", encoding: .utf8) == "selected snapshot",
              try gitRead(origin, ["rev-parse", "HEAD"]) == metadata["main"],
              try gitRead(clone, ["rev-parse", "HEAD"]) == metadata["head"] else { throw failure("Clone tree or main/HEAD incorrect") }
        if argument("--log-live-reopen") == nil {
            guard let record = store.restoreRecord(for: taskID),
                  try gitRead(clone, ["show", "refs/kaban/wip/restore-" + record.envelope.commandId.uuidString.lowercased() + ":local.txt"]) == "backup me" else { throw failure("Current edits not backed up") }
            let before = store.projection?.tasks[taskID]
            _ = await store.send(.restoreWIP(taskId: taskID, runId: runID, wipRef: ref + "-stale"), taskID: taskID)
            guard case .rejected = store.restoreRecord(for: taskID)?.phase,
                  store.projection?.tasks[taskID] == before,
                  try gitRead(origin, ["rev-parse", "HEAD"]) == metadata["main"] else { throw failure("Stale ref mutated board/main") }
        }
        return ["real bundled stdio daemon, private SQLite and git clone; Cursor never launched",
                "retained prefix 76; 1024 records keep offsets through read/tail and cleaned export",
                "native Enter submits exact selected WIP; correlated outcome refreshes durable details",
                "clone tree restored; current edits backed up; main, clone HEAD and original history preserved",
                "stale ref rejection keeps authoritative board/main; durable completion survives reopening"]
    }
}
