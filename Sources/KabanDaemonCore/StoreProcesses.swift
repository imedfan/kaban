import Foundation
import GRDB
import KabanKit
import KabanProtocol

public struct AgentProcessSnapshot: Equatable, Sendable {
    public var runId: RunID
    public var taskId: TaskID
    public var startId: String
    public var pid: Int32
    public var processGroup: Int32
    public var state: String
    public var sessionId: String?
    public var stdoutPath: String
    public var stderrPath: String
    public var workingDirectory: String
    public var exitCode: Int32?
    public var exitClass: String?
    public var passLines: [String]
    public var startedAt: Date
    public var lastActivityAt: Date
    public var stallDeadline: Date
    public var wallDeadline: Date
}

extension KabanStore {
    static func migrateAgentProcesses(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE agent_process (run_id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
    }

    /// Spawns, polls, stops, and classifies recorded runs. Poll and stop use `WNOHANG` and `kill` and do not wait.
    /// Without `runner`, a pending start stays pending. Cursor is not launched.
    public func runProcessPass(owner: String, at: Date, workspaceRoot: String, runner: String?, runnerArguments: [String] = []) throws -> [String] {
        if let runner {
            try spawnPending(owner: owner, at: at, workspaceRoot: workspaceRoot, runner: runner, arguments: runnerArguments)
        }
        try observeRunning(at: at, workspaceRoot: workspaceRoot)
        try acknowledgeStops(owner: owner, at: at)
        try acknowledgeRollbacks(owner: owner, at: at)
        return try storedProcessLines()
    }

    public func agentProcesses() throws -> [AgentProcessSnapshot] {
        try database.read { db in try Self.processRows(db).sorted { $0.runId < $1.runId }.map(\.snapshot) }
    }

    private func spawnPending(owner: String, at: Date, workspaceRoot: String, runner: String, arguments: [String]) throws {
        for item in try pendingEffectItems() {
            guard case .startAgentRun(let request) = item.effect else { continue }
            if try processRecord(request.runId) != nil { continue }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            guard task.machine.state == .running, task.machine.currentRunId == request.runId else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let stage = task.pipeline.stage(request.stageId)
            let stall = stage?.timeouts.stallSeconds ?? 600
            let wall = stage?.timeouts.wallSeconds ?? 3600
            let cwd = try workingDirectory(taskId: item.taskId, workspaceRoot: workspaceRoot)
            let logs = try logDirectory(taskId: item.taskId, workspaceRoot: workspaceRoot)
            let stdout = logs + "/" + safe(request.runId.rawValue) + ".out"
            let stderr = logs + "/" + safe(request.runId.rawValue) + ".err"
            FileManager.default.createFile(atPath: stdout, contents: Data())
            FileManager.default.createFile(atPath: stderr, contents: Data())
            let handle = try ProcessGroup.spawn(executable: runner, arguments: arguments, workingDirectory: cwd, environment: try environmentForAgentRun(taskId: item.taskId, at: at), standardOutput: stdout, standardError: stderr)
            let record = AgentProcessRecord(runId: request.runId.rawValue, taskId: item.taskId.rawValue, startId: lease.leaseId, pid: handle.pid,
                                            processGroup: handle.processGroup, birthSeconds: handle.birth.seconds, birthMicroseconds: handle.birth.microseconds,
                                            state: "running", startedAt: at, lastActivityAt: at, stallDeadline: at.addingTimeInterval(TimeInterval(stall)),
                                            wallDeadline: at.addingTimeInterval(TimeInterval(wall)), stallSeconds: stall, stdoutPath: stdout, stderrPath: stderr,
                                            workingDirectory: cwd, sessionId: nil, exitCode: nil, exitClass: nil, outputBytes: 0,
                                            passLines: ["process group \(request.runId.rawValue) started"])
            do {
                try saveProcess(record)
                try recordExternalFact(effectId: item.id, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: item.id + "/process", phase: .started))
            } catch {
                _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
                throw error
            }
        }
    }

    private func observeRunning(at: Date, workspaceRoot: String) throws {
        for var record in try allProcessRecords() where record.state == "running" {
            let run = RunID(rawValue: record.runId)
            let task = TaskID(rawValue: record.taskId)
            try captureProcessLog(stdoutPath: record.stdoutPath, stderrPath: record.stderrPath, runId: run, taskId: task, workspaceRoot: workspaceRoot, complete: false)
            if let code = ProcessGroup.poll(record.pid) {
                try captureProcessLog(stdoutPath: record.stdoutPath, stderrPath: record.stderrPath, runId: run, taskId: task, workspaceRoot: workspaceRoot, complete: true)
                try classify(&record, code: code, at: at)
            } else if !ProcessGroup.isAlive(record.pid) {
                try captureProcessLog(stdoutPath: record.stdoutPath, stderrPath: record.stderrPath, runId: run, taskId: task, workspaceRoot: workspaceRoot, complete: true)
                guard record.exitClass == nil else { continue }
                record.state = "exited"
                record.exitClass = "unobserved"
                record.passLines.append("process exit \(record.runId) unobserved")
                try saveProcess(record)
            } else {
                let size = fileSize(record.stdoutPath) + fileSize(record.stderrPath)
                if size > record.outputBytes {
                    record.outputBytes = size
                    record.lastActivityAt = at
                    record.stallDeadline = at.addingTimeInterval(TimeInterval(record.stallSeconds))
                }
                if let kind = ProcessDeadlines(stall: record.stallDeadline, wall: record.wallDeadline).due(at: at) {
                    let birth = ProcessGroup.ProcessBirth(seconds: record.birthSeconds, microseconds: record.birthMicroseconds)
                    try ProcessGroup.stop(pid: record.pid, processGroup: record.processGroup, birth: birth)
                    try captureProcessLog(stdoutPath: record.stdoutPath, stderrPath: record.stderrPath, runId: run, taskId: task, workspaceRoot: workspaceRoot, complete: true)
                    record.state = "stopped"
                    record.exitClass = kind == .wall ? "wall" : "stall"
                    record.passLines.append("process timeout \(record.runId) \(kind == .wall ? "wall" : "stall")")
                    try saveProcess(record)
                    _ = try apply(.runFailed(RunID(rawValue: record.runId), kind == .wall ? .wallTimeout : .stallTimeout), taskId: TaskID(rawValue: record.taskId), commandId: UUID(), at: at)
                } else if size > 0 {
                    try saveProcess(record)
                }
            }
        }
    }

    private static func outputExcerpt(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        return String(decoding: handle.readData(ofLength: 4_000), as: UTF8.self)
    }

    private static func limitExitClass(_ kind: CursorLimitClass) -> String {
        switch kind {
        case .rateLimit: "rate_limit"
        case .usageExhausted: "usage_exhausted"
        case .modelUnavailable: "model_unavailable"
        case .runnerAuth: "runner_auth"
        case .unknown: "unclassified"
        }
    }

    private func classify(_ record: inout AgentProcessRecord, code: Int32, at: Date) throws {
        guard record.exitClass == nil else { return }
        let taskId = TaskID(rawValue: record.taskId)
        let task = try database.read { db in try Self.task(taskId, db: db) }
        let active = task.machine.state == .running && task.machine.currentRunId?.rawValue == record.runId
        let activity = fileSize(record.stdoutPath) + fileSize(record.stderrPath) > 0
        let changed = try filesChanged(taskId)
        if active {
            let excerpt = Self.outputExcerpt(record.stdoutPath) + "\n" + Self.outputExcerpt(record.stderrPath)
            if let preview = CursorLimitClassifier.classify(excerpt, pool: nil), preview != .unknown,
               let kind = try observeAgentFailure(taskId: taskId, runId: RunID(rawValue: record.runId), text: excerpt, commandId: UUID(), at: at),
               kind != .unknown {
                record.state = "exited"
                record.exitCode = code
                record.exitClass = Self.limitExitClass(kind)
                record.passLines.append("process exit \(record.runId) \(record.exitClass ?? "limit")")
                try saveProcess(record)
                return
            }
        }
        switch ProcessExitClassifier.classify(exitCode: code, runStillActive: active, producedActivity: activity, changedFiles: changed) {
        case .noFinalCall:
            record.state = "exited"
            record.exitCode = code
            record.exitClass = "no_final_call"
            record.passLines.append("process exit \(record.runId) no_final_call")
            try saveProcess(record)
            _ = try apply(.runFailed(RunID(rawValue: record.runId), .noFinalCall), taskId: taskId, commandId: UUID(), at: at)
        case .silentDeferred:
            record.state = "exited"
            record.exitCode = code
            record.exitClass = "silent_exit"
            record.passLines.append("process exit \(record.runId) silent-exit")
            try saveProcess(record)
            _ = try apply(.runFailed(RunID(rawValue: record.runId), .silentExit), taskId: taskId, commandId: UUID(), at: at)
        case .inactive:
            record.state = "exited"
            record.exitCode = code
            record.exitClass = "ignored_late"
            record.passLines.append("process exit \(record.runId) ignored-late")
            try saveProcess(record)
        case .crash:
            record.state = "exited"
            record.exitCode = code
            record.exitClass = "crash"
            record.passLines.append("process exit \(record.runId) crash")
            try saveProcess(record)
            _ = try apply(.runFailed(RunID(rawValue: record.runId), .crash), taskId: taskId, commandId: UUID(), at: at)
        }
    }

    private func acknowledgeStops(owner: String, at: Date) throws {
        for item in try pendingEffectItems() {
            guard case .killRun(let runId) = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            if var record = try processRecord(runId), record.state == "running" {
                let birth = ProcessGroup.ProcessBirth(seconds: record.birthSeconds, microseconds: record.birthMicroseconds)
                try ProcessGroup.stop(pid: record.pid, processGroup: record.processGroup, birth: birth)
                record.state = "stopped"
                if record.exitClass == nil { record.exitClass = "killed" }
                record.passLines.append("process group \(record.runId) stopped")
                try saveProcess(record)
            }
            _ = try commitEffectResult(effectId: item.id, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: item.id + "/process-stop", phase: .finished, outcome: .acknowledged), at: at, diagnostic: "BE-08 process stop; a late exit is not a result")
        }
    }

    private func acknowledgeRollbacks(owner: String, at: Date) throws {
        for item in try pendingEffectItems() {
            guard case .saveWipAndRollback(let runId) = item.effect else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, leaseFor: 30, at: at) else { continue }
            let task = try database.read { db in try Self.task(item.taskId, db: db) }
            if let clone = try database.read({ db in try Self.cloneRecord(item.taskId, db: db) }), clone.phase == "ready" {
                let project = try database.read { db in try Self.project(task.card.projectId, db: db) }
                if let ref = try TaskClone.saveWipAndReset(clone: clone.clonePath, runId: runId, recorded: clone.clonePath, workspaceRoot: clone.workspaceRoot, origin: clone.projectPath, identity: project.summary.identity) {
                    try database.write { db in
                        var detail = try Self.detail(item.taskId, db: db)
                        if let index = detail.runs.firstIndex(where: { $0.id == runId }) { detail.runs[index].wipRef = ref }
                        try Self.saveDetail(detail, taskId: item.taskId, db: db)
                    }
                }
            }
            _ = try commitEffectResult(effectId: item.id, leaseId: lease.leaseId, fact: ExternalEffectFact(actionId: item.id + "/wip", phase: .finished, outcome: .acknowledged), at: at, diagnostic: "BE-08 wip ref stays inside the clone; restore is BE-18/19")
        }
    }

    private func filesChanged(_ taskId: TaskID) throws -> Bool {
        guard let clone = try database.read({ db in try Self.cloneRecord(taskId, db: db) }), clone.phase == "ready" else { return false }
        let identity = try database.read { db -> GitIdentity? in
            let task = try Self.task(taskId, db: db)
            return try Self.project(task.card.projectId, db: db).summary.identity
        }
        return (try? TaskClone.worktreeDirty(clone.clonePath, identity: identity)) ?? true
    }

    private func workingDirectory(taskId: TaskID, workspaceRoot: String) throws -> String {
        if let clone = try database.read({ db in try Self.cloneRecord(taskId, db: db) }), clone.phase == "ready", FileManager.default.fileExists(atPath: clone.clonePath) {
            return clone.clonePath
        }
        let path = standardize(workspaceRoot) + "/process-cwd/" + safe(taskId.rawValue)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func logDirectory(taskId: TaskID, workspaceRoot: String) throws -> String {
        let path = standardize(workspaceRoot) + "/process-logs/" + safe(taskId.rawValue)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func storedProcessLines() throws -> [String] {
        try allProcessRecords().sorted { $0.runId < $1.runId }.flatMap(\.passLines)
    }

    private func allProcessRecords() throws -> [AgentProcessRecord] {
        try database.read { db in try Self.processRows(db) }
    }

    private func processRecord(_ runId: RunID) throws -> AgentProcessRecord? {
        try database.read { db in try Self.processRow(runId, db: db) }
    }

    private func saveProcess(_ record: AgentProcessRecord) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO agent_process(run_id, payload) VALUES (?, ?) ON CONFLICT(run_id) DO UPDATE SET payload = excluded.payload", arguments: [record.runId, try Self.encode(record)])
        }
    }

    static func processRows(_ db: Database) throws -> [AgentProcessRecord] {
        try Data.fetchAll(db, sql: "SELECT payload FROM agent_process ORDER BY run_id").map { try decode(AgentProcessRecord.self, $0) }
    }

    static func processRow(_ runId: RunID, db: Database) throws -> AgentProcessRecord? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM agent_process WHERE run_id = ?", arguments: [runId.rawValue]) else { return nil }
        return try decode(AgentProcessRecord.self, data)
    }

    static func minimalEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        return env
    }

    private func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private func safe(_ raw: String) -> String {
        let text = String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return text.isEmpty ? "run" : text
    }

    private func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

struct AgentProcessRecord: Codable, Equatable {
    var runId: String
    var taskId: String
    var startId: String
    var pid: Int32
    var processGroup: Int32
    var birthSeconds: Int64
    var birthMicroseconds: Int32
    var state: String
    var startedAt: Date
    var lastActivityAt: Date
    var stallDeadline: Date
    var wallDeadline: Date
    var stallSeconds: Int
    var stdoutPath: String
    var stderrPath: String
    var workingDirectory: String
    var sessionId: String?
    var exitCode: Int32?
    var exitClass: String?
    var outputBytes: Int64
    var passLines: [String]

    var snapshot: AgentProcessSnapshot {
        .init(runId: RunID(rawValue: runId), taskId: TaskID(rawValue: taskId), startId: startId, pid: pid, processGroup: processGroup, state: state,
              sessionId: sessionId, stdoutPath: stdoutPath, stderrPath: stderrPath, workingDirectory: workingDirectory, exitCode: exitCode, exitClass: exitClass,
              passLines: passLines, startedAt: startedAt, lastActivityAt: lastActivityAt, stallDeadline: stallDeadline, wallDeadline: wallDeadline)
    }
}
