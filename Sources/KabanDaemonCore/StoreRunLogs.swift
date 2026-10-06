import Foundation
import GRDB
import KabanKit
import KabanProtocol

/// How many normalized events one run keeps. Older offsets stay numbered and become `log_offset_expired`.
public enum RunLogRetention {
    public static let maxEvents = 1024
    public static let maxFileBytes = 1_048_576
}

extension KabanStore {
    static func migrateRunLogs(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE run_log (
                run_id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                path TEXT NOT NULL,
                stderr_path TEXT NOT NULL,
                available_from INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                complete INTEGER NOT NULL,
                pending BLOB NOT NULL,
                skipping INTEGER NOT NULL,
                stdout_bytes INTEGER NOT NULL,
                stderr_bytes INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE run_log_event (
                run_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                payload BLOB NOT NULL,
                source TEXT NOT NULL,
                PRIMARY KEY (run_id, seq)
            )
            """)
    }

    /// Parse one redacted stdout chunk into durable AgentEvent offsets. The same function serves the process observer.
    /// A read never consumes those rows. Retention drops a prefix without renumbering the events that remain.
    public func ingestAgentOutput(runId: RunID, taskId: TaskID, chunk: Data, stderr: Data = Data(), complete: Bool = false,
                                  directory: String, extras: [String] = [], consumedStdout: Int64? = nil, consumedStderr: Int64? = nil) throws {
        _ = try database.read { db in try Self.task(taskId, db: db) }
        let stdoutText = SecretText.redact(String(decoding: chunk, as: UTF8.self), extras: extras)
        let stderrText = SecretText.redact(String(decoding: stderr, as: UTF8.self), extras: extras)
        let logs = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let safe = Self.safeLogName(runId.rawValue)
        let path = logs.appendingPathComponent(safe + ".jsonl").path
        let stderrPath = logs.appendingPathComponent(safe + ".err").path
        try database.write { db in
            var row = try Self.runLogRow(runId, db: db) ?? RunLogRow(runId: runId.rawValue, taskId: taskId.rawValue, path: path, stderrPath: stderrPath,
                                                                      availableFrom: 0, endOffset: 0, complete: false, pending: Data(), skipping: false,
                                                                      stdoutBytes: 0, stderrBytes: 0)
            guard row.taskId == taskId.rawValue else { throw StoreError.rejected(CommandError(code: "invalid_request", message: "Лог принадлежит другой задаче.")) }
            row.path = path
            row.stderrPath = stderrPath
            var parser = CursorStreamParser()
            parser.resume(remainder: row.pending, skipping: row.skipping)
            let batch = parser.append(Data(stdoutText.utf8))
            row.pending = parser.remainder
            row.skipping = parser.skippingRemainder
            if batch.events.count != batch.sources.count { throw StoreError.incompleteProjection }
            var seq = row.endOffset
            for (event, source) in zip(batch.events, batch.sources) {
                let redacted = SecretText.redact(event, extras: extras)
                let line = SecretText.redact(source, extras: extras)
                try db.execute(sql: "INSERT INTO run_log_event(run_id, seq, payload, source) VALUES (?, ?, ?, ?)",
                               arguments: [runId.rawValue, seq, try Self.encode(redacted), line])
                seq += 1
            }
            row.endOffset = seq
            if complete { row.complete = true }
            if let consumedStdout { row.stdoutBytes = consumedStdout }
            if let consumedStderr { row.stderrBytes = consumedStderr }
            let retainedFrom = max(row.availableFrom, row.endOffset - Int64(RunLogRetention.maxEvents))
            if retainedFrom > row.availableFrom {
                try db.execute(sql: "DELETE FROM run_log_event WHERE run_id = ? AND seq < ?", arguments: [runId.rawValue, retainedFrom])
                row.availableFrom = retainedFrom
            }
            if !stderrText.isEmpty {
                if FileManager.default.fileExists(atPath: stderrPath), let handle = FileHandle(forWritingAtPath: stderrPath) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(stderrText.utf8))
                } else {
                    try Data(stderrText.utf8).write(to: URL(fileURLWithPath: stderrPath), options: .atomic)
                }
            }
            try Self.rewriteRunLog(row, db: db)
            try Self.saveRunLog(row, db: db)
            try Self.attachLogPath(runId, taskId: taskId, path: path, db: db)
        }
    }

    /// One page of normalized events. A missing file is `log_unavailable`. A trimmed prefix is `log_offset_expired`.
    /// An empty page is only the caught-up cursor (`fromOffset == endOffset`).
    public func readLog(runId: RunID, fromOffset: Int64, limit: Int) throws -> LogPage {
        guard fromOffset >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
            throw CommandError(code: "invalid_request", message: "Некорректное смещение или размер пакета лога.")
        }
        return try database.read { db in
            guard let row = try Self.runLogRow(runId, db: db) else {
                throw CommandError(code: CommandError.logUnavailableCode, message: "Лог недоступен.")
            }
            guard FileManager.default.fileExists(atPath: row.path) else {
                throw CommandError(code: CommandError.logUnavailableCode, message: "Лог недоступен.")
            }
            if fromOffset < row.availableFrom {
                throw CommandError(code: CommandError.logOffsetExpiredCode, message: "Начало лога уже удалено.",
                                   params: ["availableFromOffset": String(row.availableFrom)])
            }
            guard fromOffset <= row.endOffset else {
                throw CommandError(code: "invalid_request", message: "Смещение за концом лога.")
            }
            let next = min(fromOffset + Int64(limit), row.endOffset)
            let payloads = try Data.fetchAll(db, sql: "SELECT payload FROM run_log_event WHERE run_id = ? AND seq >= ? AND seq < ? ORDER BY seq",
                                              arguments: [runId.rawValue, fromOffset, next])
            let events = try payloads.map { try Self.decode(AgentEvent.self, $0) }
            guard Int64(events.count) == next - fromOffset else { throw StoreError.incompleteProjection }
            return LogPage(batch: LogBatch(runId: runId, fromOffset: fromOffset, nextOffset: next, events: events),
                           availableFromOffset: row.availableFrom, endOffset: row.endOffset, isComplete: row.complete)
        }
    }

    /// Reprint stored pages through the same reader the client uses. It does not launch Cursor.
    public func runLogPass() throws -> [String] {
        let ids = try database.read { db in try String.fetchAll(db, sql: "SELECT run_id FROM run_log ORDER BY run_id") }
        var lines: [String] = []
        for id in ids {
            let run = RunID(rawValue: id)
            do {
                let page = try readLog(runId: run, fromOffset: 0, limit: 1)
                lines.append("log \(id) \(page.availableFromOffset) \(page.batch.nextOffset) \(page.endOffset) \(page.isComplete ? "complete" : "live")")
            } catch let error as CommandError where error.code == CommandError.logOffsetExpiredCode {
                lines.append("log \(id) expired \(error.params["availableFromOffset"] ?? "")")
            } catch let error as CommandError where error.code == CommandError.logUnavailableCode {
                lines.append("log \(id) unavailable")
            }
        }
        return lines
    }

    /// Read new process bytes and append them. A slow reader is not in this path: the write does not wait on `readLog`.
    func captureProcessLog(stdoutPath: String, stderrPath: String, runId: RunID, taskId: TaskID, workspaceRoot: String, complete: Bool) throws {
        let existing = try database.read { db in try Self.runLogRow(runId, db: db) }
        let (stdout, stdoutBytes) = Self.logSlice(path: stdoutPath, from: existing?.stdoutBytes ?? 0)
        let (stderr, stderrBytes) = Self.logSlice(path: stderrPath, from: existing?.stderrBytes ?? 0)
        if stdout.isEmpty && stderr.isEmpty && existing == nil && !complete { return }
        if stdout.isEmpty && stderr.isEmpty && existing == nil { return }
        try ingestAgentOutput(runId: runId, taskId: taskId, chunk: stdout, stderr: stderr, complete: complete, directory: workspaceRoot,
                              consumedStdout: stdoutBytes, consumedStderr: stderrBytes)
        if complete {
            SecretText.redactFile(stdoutPath)
            SecretText.redactFile(stderrPath)
        }
    }

    private static func logSlice(path: String, from: Int64) -> (Data, Int64) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > from, let handle = FileHandle(forReadingAtPath: path) else { return (Data(), max(size, from)) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(max(from, 0)))
        return (handle.readDataToEndOfFile(), size)
    }

    private static func rewriteRunLog(_ row: RunLogRow, db: Database) throws {
        let sources = try String.fetchAll(db, sql: "SELECT source FROM run_log_event WHERE run_id = ? AND seq >= ? ORDER BY seq",
                                           arguments: [row.runId, row.availableFrom])
        var text = sources.map { $0 + "\n" }.joined()
        let limit = RunLogRetention.maxFileBytes
        if text.utf8.count > limit, sources.count > 1 {
            var kept = sources
            while kept.count > 1 {
                let bytes = kept.map({ $0 + "\n" }).joined().utf8.count
                if bytes <= limit { break }
                kept.removeFirst()
            }
            let drop = sources.count - kept.count
            if drop > 0 {
                let boundary = row.availableFrom + Int64(drop)
                try db.execute(sql: "DELETE FROM run_log_event WHERE run_id = ? AND seq < ?", arguments: [row.runId, boundary])
                text = kept.map { $0 + "\n" }.joined()
            }
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: row.path), options: .atomic)
    }

    private static func attachLogPath(_ runId: RunID, taskId: TaskID, path: String, db: Database) throws {
        guard var detail = try? Self.detail(taskId, db: db), let index = detail.runs.firstIndex(where: { $0.id == runId }) else { return }
        guard detail.runs[index].logPath != path else { return }
        detail.runs[index].logPath = path
        try saveDetail(detail, taskId: taskId, db: db)
    }

    private static func safeLogName(_ raw: String) -> String {
        let text = String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return text.isEmpty ? "run" : text
    }
}

private struct RunLogRow {
    var runId: String
    var taskId: String
    var path: String
    var stderrPath: String
    var availableFrom: Int64
    var endOffset: Int64
    var complete: Bool
    var pending: Data
    var skipping: Bool
    var stdoutBytes: Int64
    var stderrBytes: Int64
}

extension KabanStore {
    fileprivate static func runLogRow(_ runId: RunID, db: Database) throws -> RunLogRow? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT run_id, task_id, path, stderr_path, available_from, end_offset, complete, pending, skipping, stdout_bytes, stderr_bytes
            FROM run_log WHERE run_id = ?
            """, arguments: [runId.rawValue]) else { return nil }
        return RunLogRow(runId: row["run_id"], taskId: row["task_id"], path: row["path"], stderrPath: row["stderr_path"],
                         availableFrom: row["available_from"], endOffset: row["end_offset"], complete: (row["complete"] as Int64) != 0,
                         pending: row["pending"], skipping: (row["skipping"] as Int64) != 0, stdoutBytes: row["stdout_bytes"], stderrBytes: row["stderr_bytes"])
    }

    fileprivate static func saveRunLog(_ row: RunLogRow, db: Database) throws {
        // File-size retention may have deleted a further prefix inside rewrite. Read it back before saving.
        let available = try Int64.fetchOne(db, sql: "SELECT MIN(seq) FROM run_log_event WHERE run_id = ?", arguments: [row.runId])
        let end = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM run_log_event WHERE run_id = ?", arguments: [row.runId])
        let availableFrom = available ?? row.endOffset
        let endOffset = end.map { $0 + 1 } ?? row.endOffset
        try db.execute(sql: """
            INSERT INTO run_log(run_id, task_id, path, stderr_path, available_from, end_offset, complete, pending, skipping, stdout_bytes, stderr_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                task_id = excluded.task_id, path = excluded.path, stderr_path = excluded.stderr_path,
                available_from = excluded.available_from, end_offset = excluded.end_offset, complete = excluded.complete,
                pending = excluded.pending, skipping = excluded.skipping, stdout_bytes = excluded.stdout_bytes, stderr_bytes = excluded.stderr_bytes
            """, arguments: [row.runId, row.taskId, row.path, row.stderrPath, availableFrom, endOffset, row.complete ? 1 : 0,
                             row.pending, row.skipping ? 1 : 0, row.stdoutBytes, row.stderrBytes])
    }
}
