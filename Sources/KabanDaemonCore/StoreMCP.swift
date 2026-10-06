import Foundation
import GRDB
import KabanKit
import KabanProtocol

enum BoardFailure: Error, Equatable {
    case unauthorized(String)
    case rejected(String)
    case invalid(String)
}

struct BoardToolResponse: Equatable {
    var message: String
    var notices: [String]
    var taskId: String
    var projectId: String
    var stageId: String
    var runId: String
    var title: String
    var body: String?
    var state: String
}

extension KabanStore {
    static func migrateMCPTokens(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE mcp_run_token (
            token_hash TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            task_id TEXT NOT NULL,
            stage_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            revoked INTEGER NOT NULL,
            complete_command_id TEXT
        )
        """)
        try db.execute(sql: "CREATE TABLE mcp_pass_line (run_id TEXT PRIMARY KEY NOT NULL, line TEXT NOT NULL)")
    }

    /// Raw token is returned once for the process environment. The database keeps only its hash.
    public func issueRunToken(taskId: TaskID, at: Date) throws -> String {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in try Self.issueRunToken(taskId, at: at, db: db) }
    }

    /// Environment for one agent process. `KABAN_RUN_TOKEN` is not copied into the process record.
    public func environmentForAgentRun(taskId: TaskID, at: Date) throws -> [String: String] {
        var env = Self.minimalEnvironment()
        env["KABAN_RUN_TOKEN"] = try issueRunToken(taskId: taskId, at: at)
        return env
    }

    public func queueGitGrantNotice(taskId: TaskID, argv: [String], at: Date) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        try database.write { db in
            let task = try Self.task(taskId, db: db)
            var detail = try Self.detail(taskId, db: db)
            let grant = GitGrantCreated(grantId: GrantID(rawValue: "grant-\(UUID().uuidString.lowercased())"), denialId: DenialID(rawValue: "denial-\(UUID().uuidString.lowercased())"), argv: argv, by: .human)
            detail.gitGrants.append(GitGrantSnapshot(grant: grant, taskId: taskId, stageId: task.machine.stageId, createdAt: at))
            try Self.saveDetail(detail, taskId: taskId, db: db)
        }
    }

    func requireBoardToken(_ token: String) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        try database.read { db in
            guard try Self.tokenRow(SHA256Digest.hex(token), db: db) != nil else {
                throw BoardFailure.unauthorized("Токен не подходит к этому запуску.")
            }
        }
    }

    func performBoardTool(token: String, name: String, arguments: [String: Any], at: Date) throws -> BoardToolResponse {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in try Self.performBoardTool(token: token, name: name, arguments: arguments, at: at, db: db) }
    }

    /// One completion through the loopback server. A later pass reprints the stored line.
    public func runMCPPass(at: Date) throws -> [String] {
        let stored = try database.read { db in try String.fetchAll(db, sql: "SELECT line FROM mcp_pass_line ORDER BY run_id") }
        if !stored.isEmpty { return stored }
        let running = try database.read { db in
            try Self.allTasks(db).filter { $0.machine.state == .running && $0.machine.currentRunId != nil }
                .sorted { ($0.machine.currentRunId?.rawValue ?? "") < ($1.machine.currentRunId?.rawValue ?? "") }
        }
        guard let task = running.first, let run = task.machine.currentRunId else { return [] }
        let server = try MCPBoardServer(store: self, now: { at })
        defer { server.stop() }
        let token = try issueRunToken(taskId: task.card.id, at: at)
        _ = try server.roundTrip(token: token, method: "tools/call", params: [
            "name": "complete_stage",
            "arguments": ["summary": "mcp pass"],
        ])
        let line = "mcp complete \(run.rawValue) gating"
        try database.write { db in
            try db.execute(sql: "INSERT INTO mcp_pass_line(run_id, line) VALUES (?, ?)", arguments: [run.rawValue, line])
        }
        return [line]
    }

    static func revokeMCPTokens(runId: RunID?, db: Database) throws {
        guard let runId else { return }
        try db.execute(sql: "UPDATE mcp_run_token SET revoked = 1 WHERE run_id = ?", arguments: [runId.rawValue])
    }

    private static func issueRunToken(_ taskId: TaskID, at: Date, db: Database) throws -> String {
        let task = try task(taskId, db: db)
        guard task.machine.state == .running, let run = task.machine.currentRunId else { throw StoreError.rejected(CommandError(code: "invalid_state", message: "Токен выдаётся только живому run.")) }
        try db.execute(sql: "UPDATE mcp_run_token SET revoked = 1 WHERE run_id = ?", arguments: [run.rawValue])
        let raw = randomToken()
        try db.execute(sql: "INSERT INTO mcp_run_token(token_hash, project_id, task_id, stage_id, run_id, revoked, complete_command_id) VALUES (?, ?, ?, ?, ?, 0, NULL)", arguments: [
            SHA256Digest.hex(raw), task.card.projectId.rawValue, taskId.rawValue, task.machine.stageId.rawValue, run.rawValue,
        ])
        _ = at
        return raw
    }

    private static func performBoardTool(token: String, name: String, arguments: [String: Any], at: Date, db: Database) throws -> BoardToolResponse {
        guard let row = try tokenRow(SHA256Digest.hex(token), db: db) else {
            throw BoardFailure.unauthorized("Токен не подходит к этому запуску.")
        }
        if let claimed = arguments["taskId"] as? String, claimed != row.taskId {
            throw BoardFailure.rejected("Задача не совпадает с токеном.")
        }
        let taskId = TaskID(rawValue: row.taskId)
        let task = try task(taskId, db: db)
        if row.projectId != task.card.projectId.rawValue {
            throw BoardFailure.unauthorized("Токен не подходит к этому запуску.")
        }
        let live = task.machine.state == .running && task.machine.currentRunId?.rawValue == row.runId && task.machine.stageId.rawValue == row.stageId
        if name == "complete_stage", row.completeCommandId != nil || completedRun(row, task) {
            let notices = try consumeNotices(taskId: taskId, runId: row.runId, at: at, db: db)
            return try response(task, runId: row.runId, message: "complete_stage already recorded", notices: notices, db: db)
        }
        if row.revoked || !live {
            throw BoardFailure.unauthorized("Токен не подходит к этому запуску.")
        }
        switch name {
        case "get_task_context":
            let notices = try consumeNotices(taskId: taskId, runId: row.runId, at: at, db: db)
            return try response(task, runId: row.runId, message: "context", notices: notices, db: db)
        case "report_progress":
            let text = try bounded(arguments["text"] as? String, field: "text")
            try reportProgress(text, taskId: taskId, runId: RunID(rawValue: row.runId), at: at, db: db)
            let notices = try consumeNotices(taskId: taskId, runId: row.runId, at: at, db: db)
            let updated = try self.task(taskId, db: db)
            return try response(updated, runId: row.runId, message: text, notices: notices, db: db)
        case "complete_stage":
            let summary = try bounded(arguments["summary"] as? String, field: "summary")
            let artifacts = try artifactTexts(arguments["artifacts"])
            let commandId = stableCommandID("complete:\(row.tokenHash)")
            let run = RunID(rawValue: row.runId)
            do {
                _ = try apply(.completeStage(run, summary: summary), taskId: taskId, commandId: commandId, at: at, request: try encode(Request(kind: "transition", taskId: taskId, body: encode(DurableTaskCommand.completeStage(run, summary: summary)))), db: db)
            } catch StoreError.commandIdConflict {
                // The same final call already has a receipt. A second summary must not transition again.
            }
            try db.execute(sql: "UPDATE mcp_run_token SET revoked = 1, complete_command_id = ? WHERE token_hash = ?", arguments: [commandId.uuidString, row.tokenHash])
            try appendArtifacts(artifacts, taskId: taskId, runId: run, stageId: StageID(rawValue: row.stageId), commandId: commandId, at: at, db: db)
            let notices = try consumeNotices(taskId: taskId, runId: row.runId, at: at, db: db)
            return try response(try self.task(taskId, db: db), runId: row.runId, message: summary, notices: notices, db: db)
        case "return_to_stage":
            let target = try bounded(arguments["target"] as? String, field: "target")
            let issues = try issueTexts(arguments["issues"])
            let run = RunID(rawValue: row.runId)
            let command = DurableTaskCommand.returnToStage(run, target: StageID(rawValue: target), issues: issues)
            do {
                _ = try apply(command, taskId: taskId, commandId: UUID(), at: at, request: try encode(Request(kind: "transition", taskId: taskId, body: encode(command))), db: db)
            } catch let error as StoreError {
                if case .rejected(let commandError) = error { throw BoardFailure.rejected(commandError.message) }
                throw error
            }
            let notices = try consumeNotices(taskId: taskId, runId: row.runId, at: at, db: db)
            return try response(try self.task(taskId, db: db), runId: row.runId, message: issues.joined(separator: "\n"), notices: notices, db: db)
        case "request_human":
            let question = try bounded(arguments["question"] as? String, field: "question")
            let run = RunID(rawValue: row.runId)
            let command = DurableTaskCommand.requestHuman(run, question: question)
            _ = try apply(command, taskId: taskId, commandId: UUID(), at: at, request: try encode(Request(kind: "transition", taskId: taskId, body: encode(command))), db: db)
            let notices = try consumeNotices(taskId: taskId, runId: row.runId, at: at, db: db)
            return try response(try self.task(taskId, db: db), runId: row.runId, message: question, notices: notices, db: db)
        default:
            throw BoardFailure.invalid("Неизвестный инструмент \(name).")
        }
    }

    struct TokenRow {
        var tokenHash: String
        var projectId: String
        var taskId: String
        var stageId: String
        var runId: String
        var revoked: Bool
        var completeCommandId: String?
    }

    static func tokenRow(_ hash: String, db: Database) throws -> TokenRow? {
        guard let row = try Row.fetchOne(db, sql: "SELECT token_hash, project_id, task_id, stage_id, run_id, revoked, complete_command_id FROM mcp_run_token WHERE token_hash = ?", arguments: [hash]) else { return nil }
        return TokenRow(tokenHash: row["token_hash"], projectId: row["project_id"], taskId: row["task_id"], stageId: row["stage_id"], runId: row["run_id"], revoked: (row["revoked"] as Int64) != 0, completeCommandId: row["complete_command_id"])
    }

    private static func completedRun(_ row: TokenRow, _ task: DurableTask) -> Bool {
        guard task.machine.lastRunId?.rawValue == row.runId, task.machine.state != .running else { return false }
        return task.machine.state == .gating && task.machine.stageId.rawValue == row.stageId
    }

    private static func reportProgress(_ text: String, taskId: TaskID, runId: RunID, at: Date, db: Database) throws {
        var task = try task(taskId, db: db)
        let state = task.machine.state
        var detail = try detail(taskId, db: db)
        detail.feed.append(FeedItem(id: "progress-\(UUID().uuidString.lowercased())", at: at, kind: "progress", text: text, runId: runId))
        try saveDetail(detail, taskId: taskId, db: db)
        task.card.updatedAt = at
        guard task.machine.state == state else { throw StoreError.rejected(CommandError(code: "invalid_state", message: "progress не меняет статус")) }
        try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try encode(task), taskId.rawValue])
        _ = try journal(.taskUpdated(task.card), task: task, commandId: UUID(), at: at, db: db)
        if var record = try processRow(runId, db: db) {
            record.lastActivityAt = at
            try db.execute(sql: "UPDATE agent_process SET payload = ? WHERE run_id = ?", arguments: [try encode(record), runId.rawValue])
        }
    }

    private static func appendArtifacts(_ texts: [(String, String)], taskId: TaskID, runId: RunID, stageId: StageID, commandId: CommandID, at: Date, db: Database) throws {
        guard !texts.isEmpty else { return }
        var detail = try detail(taskId, db: db)
        for (offset, item) in texts.enumerated() {
            let id = "\(commandId.uuidString.lowercased())/artifact/\(offset)"
            guard !detail.artifacts.contains(where: { $0.id.rawValue == id }) else { continue }
            detail.artifacts.append(TaskArtifact(id: ArtifactID(rawValue: id), taskId: taskId, runId: runId, stageId: stageId, kind: item.0, text: item.1, createdAt: at))
        }
        try saveDetail(detail, taskId: taskId, db: db)
    }

    private static func consumeNotices(taskId: TaskID, runId: String, at: Date, db: Database) throws -> [String] {
        var detail = try detail(taskId, db: db)
        var notes: [String] = []
        var delivered: [GitGrantDelivered] = []
        for index in detail.gitGrants.indices {
            let grant = detail.gitGrants[index]
            guard grant.taskId == taskId, grant.delivery == nil, grant.revocation == nil, grant.expiry == nil, grant.consumption == nil else { continue }
            let delivery = GitGrantDelivered(grantId: grant.grant.grantId, runId: RunID(rawValue: runId), via: .mcpResponse)
            detail.gitGrants[index].delivery = delivery
            detail.gitGrants[index].deliveredAt = at
            delivered.append(delivery)
            notes.append("\(grant.grant.argv.joined(separator: " ")) разрешена один раз")
        }
        if !notes.isEmpty {
            try saveDetail(detail, taskId: taskId, db: db)
            let owner = try task(taskId, db: db)
            for delivery in delivered {
                _ = try journal(.gitGrantDelivered(delivery), task: owner, commandId: UUID(), at: at, db: db)
            }
        }
        return notes
    }

    private static func response(_ task: DurableTask, runId: String, message: String, notices: [String], db: Database) throws -> BoardToolResponse {
        let detail = try detail(task.card.id, db: db)
        return BoardToolResponse(message: message, notices: notices, taskId: task.card.id.rawValue, projectId: task.card.projectId.rawValue, stageId: task.machine.stageId.rawValue, runId: runId, title: task.card.title, body: detail.body, state: task.machine.state.status.rawValue)
    }

    private static func bounded(_ value: String?, field: String) throws -> String {
        guard let value else { throw BoardFailure.invalid("Нет поля \(field).") }
        guard value.utf8.count <= 4_096 else { throw BoardFailure.invalid("Поле \(field) длиннее 4096 байт.") }
        return value
    }

    private static func issueTexts(_ value: Any?) throws -> [String] {
        guard let list = value as? [Any] else { throw BoardFailure.invalid("issues должен быть списком строк.") }
        guard list.count <= 20 else { throw BoardFailure.invalid("Слишком много issues.") }
        return try list.map { item in
            guard let text = item as? String else { throw BoardFailure.invalid("issues должен быть списком строк.") }
            return try bounded(text, field: "issues")
        }
    }

    private static func artifactTexts(_ value: Any?) throws -> [(String, String)] {
        guard let value else { return [] }
        guard let list = value as? [Any] else { throw BoardFailure.invalid("artifacts должен быть списком объектов.") }
        guard list.count <= 20 else { throw BoardFailure.invalid("Слишком много artifacts.") }
        return try list.map { item in
            guard let object = item as? [String: Any] else { throw BoardFailure.invalid("artifacts должен быть списком объектов.") }
            return (try bounded(object["kind"] as? String, field: "kind"), try bounded(object["text"] as? String, field: "text"))
        }
    }

    private static func stableCommandID(_ name: String) -> UUID {
        let hex = SHA256Digest.hex(name)
        let text = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: text) ?? UUID()
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let fd = open("/dev/urandom", O_RDONLY)
        if fd >= 0 {
            _ = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, 32) }
            close(fd)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
