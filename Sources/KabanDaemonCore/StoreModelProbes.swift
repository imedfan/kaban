import Foundation
import GRDB
import KabanKit
import KabanProtocol

/// A probe has its own process identity and never creates a task run or an admission.
struct ModelProbeProcess: Codable {
    var id: UUID
    var model: ModelID
    var pool: ModelPool
    var startedAt: Date
    var deadline: Date
    var handlePID: Int32
    var birth: ProcessGroup.ProcessBirth
    var directory: String
    var finished: Bool = false
    var observed: Bool = false
    var outcome: ProbeOutcome?
    var resetAt: Date?
    var waiters: [TaskID: RunID]
    var modelFlag: ModelFlag?
    var usageFlags: [SchedulerFlag]
    var usageGenerations: [String: String]
    var catalog: [ModelInfo]
}

extension KabanStore {
    static func migrateModelProbeProcesses(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE model_probe_process(model TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE usage_probe_due(scope TEXT PRIMARY KEY NOT NULL, next_at REAL NOT NULL, generation TEXT NOT NULL)")
    }

    static func probeProcesses(_ db: Database) throws -> [ModelProbeProcess] {
        try Data.fetchAll(db, sql: "SELECT payload FROM model_probe_process ORDER BY model").map { try decode(ModelProbeProcess.self, $0) }
    }

    static func saveProbeProcess(_ record: ModelProbeProcess, db: Database) throws {
        try db.execute(sql: "INSERT INTO model_probe_process(model, payload) VALUES (?, ?) ON CONFLICT(model) DO UPDATE SET payload = excluded.payload",
                       arguments: [record.model.rawValue, try encode(record)])
    }

    /// Reservations count before spawn; a process still stopping after a task transition also holds its slot.
    static func agentProcessLoad(_ db: Database) throws -> Int {
        let reserved = try Set(allTasks(db).filter { $0.machine.state == .running }.compactMap { $0.machine.currentRunId?.rawValue })
        let physical = try Set(processRows(db).filter { $0.state == "running" }.map(\.runId))
        return reserved.union(physical).count + (try probeProcesses(db).filter { !$0.finished }.count)
    }

    /// Nonblocking runtime producer. Uses the configured Cursor executable and environment, never the task test runner.
    public func runModelProbePass(at: Date, workspaceRoot: String) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        for record in try database.read({ try Self.probeProcesses($0) }) {
            if record.finished { try? FileManager.default.removeItem(atPath: record.directory) }
            else { try pollModelProbe(record, at: at) }
        }
        guard let executable = try database.read({ try Self.runnerState($0).executable }),
              CursorRunner.executableState(executable) == .runnable else { return }
        let candidates = try database.write { db -> [ModelID] in
            let inputs = try Self.schedulerInputs(db)
            let flags = try Self.schedulerFlags(db)
            guard !flags.contains(where: { flag in
                switch flag {
                case .macPaused, .runnerUnavailable: true
                case .rateLimited(let until, _): until > at
                default: false
                }
            }), try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM global_settings)") == true else { return [] }
            let tasks = try Self.allTasks(db)
            var models = Set(inputs.modelFlags.map(\.modelId))
            for task in tasks where task.machine.state == .retryWait(.silentExit) {
                if let model = try Self.probeModel(task, db: db) { models.insert(model) }
            }
            let catalog = try Self.catalogRecord(db).rows.filter { !$0.forbidden && $0.missingSince == nil }
            for flag in inputs.flags {
                guard let scope = Self.unknownUsageScope(flag) else { continue }
                // Legacy nil flags have no observation time. Start their six-hour clock on first observation.
                try db.execute(sql: "INSERT INTO usage_probe_due(scope, next_at, generation) VALUES (?, ?, ?) ON CONFLICT(scope) DO NOTHING",
                               arguments: [scope, at.addingTimeInterval(CursorLimitClassifier.usageProbeInterval).timeIntervalSince1970, UUID().uuidString])
                let pool = ModelPool(rawValue: scope)
                let known = try tasks.compactMap { try Self.probeModel($0, db: db) } + catalog.map(\.id)
                if let model = known.sorted { $0.rawValue < $1.rawValue }.first(where: { pool == nil || ModelPoolResolver.pool(for: $0, rules: inputs.modelPoolRules) == pool }) {
                    models.insert(model)
                }
            }
            return models.sorted { $0.rawValue < $1.rawValue }
        }
        for model in candidates {
            let reservation = try database.write { db -> ModelProbeProcess? in
                guard try Self.agentProcessLoad(db) < Self.settings(db).maxConcurrentRuns else { return nil }
                let existing = try Self.probeProcesses(db).first { $0.model == model }
                guard existing?.finished != false,
                      existing.map({ $0.startedAt.addingTimeInterval(CursorLimitClassifier.probeInterval) <= at }) ?? true else { return nil }
                let inputs = try Self.schedulerInputs(db)
                let pool = ModelPoolResolver.pool(for: model, rules: inputs.modelPoolRules)
                guard !inputs.flags.contains(where: { flag in
                    switch flag {
                    case .usageExhaustedUnknown(let reset): reset.map { $0 > at } ?? false
                    case .poolUsageExhausted(let blocked, let reset): blocked == pool && (reset.map { $0 > at } ?? false)
                    default: false
                    }
                }) else { return nil }
                let usage = inputs.flags.filter { flag in
                    switch flag {
                    case .usageExhaustedUnknown(nil), .poolUsageExhausted(pool, nil): true
                    default: false
                    }
                }
                for flag in usage {
                    if let scope = Self.unknownUsageScope(flag),
                       let next = try Double.fetchOne(db, sql: "SELECT next_at FROM usage_probe_due WHERE scope = ?", arguments: [scope]),
                       next > at.timeIntervalSince1970 { return nil }
                    // A second model must not probe the same exhausted scope concurrently.
                    if try Self.probeProcesses(db).contains(where: { !$0.finished && $0.usageFlags.contains(flag) }) { return nil }
                }
                var waiters: [TaskID: RunID] = [:]
                for task in try Self.allTasks(db) where task.machine.state == .retryWait(.silentExit) {
                    if try Self.probeModel(task, db: db) == model, let run = task.machine.lastRunId { waiters[task.card.id] = run }
                }
                let id = UUID()
                let directory = URL(fileURLWithPath: workspaceRoot).appendingPathComponent("model-probes").appendingPathComponent(id.uuidString).path
                let record = ModelProbeProcess(id: id, model: model, pool: pool, startedAt: at, deadline: at.addingTimeInterval(60),
                    handlePID: 0, birth: .init(seconds: 0, microseconds: 0), directory: directory, waiters: waiters,
                    modelFlag: inputs.modelFlags.first { $0.modelId == model }, usageFlags: usage,
                    usageGenerations: Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT scope, generation FROM usage_probe_due").map { ($0["scope"] as String, $0["generation"] as String) }), catalog: try Self.catalogRecord(db).rows)
                try Self.saveProbeProcess(record, db: db)
                for flag in usage {
                    if let scope = Self.unknownUsageScope(flag) {
                        try db.execute(sql: "UPDATE usage_probe_due SET next_at = ? WHERE scope = ?",
                                       arguments: [at.addingTimeInterval(CursorLimitClassifier.usageProbeInterval).timeIntervalSince1970, scope])
                    }
                }
                try db.execute(sql: "INSERT INTO model_probe(model, requested_at, next_at) VALUES (?, ?, ?) ON CONFLICT(model) DO UPDATE SET requested_at = excluded.requested_at, next_at = excluded.next_at",
                               arguments: [model.rawValue, at.timeIntervalSince1970, at.addingTimeInterval(CursorLimitClassifier.probeInterval).timeIntervalSince1970])
                return record
            }
            guard var record = reservation else { continue }
            do {
                try FileManager.default.createDirectory(atPath: record.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let inherited = try cursorProcessEnvironment()
                let home = URL(fileURLWithPath: record.directory).appendingPathComponent("home")
                var environment = try CursorRunHome.environment(inherited, home: home)
                for key in ["KABAN_RUN_TOKEN", "KABAN_MCP_URL", "KABAN_GIT_CHECK_URL"] { environment[key] = nil }
                let cwd = URL(fileURLWithPath: record.directory).appendingPathComponent("work")
                try FileManager.default.createDirectory(at: cwd.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
                try Data(#"{"mcpServers":{}}"#.utf8).write(to: cwd.appendingPathComponent(".cursor/mcp.json"), options: .atomic)
                // No project cwd, run token, resume or --force. A probe only asks for a short reply.
                let plan = try CursorLaunch.plan(model: model.rawValue, readOnly: true, resumeRequested: false, verifiedSessionId: nil,
                    prompt: "Reply with OK only. Do not use tools, inspect files, or change anything.", environment: environment)
                let gate = record.directory + "/start"
                let launcher = "i=0; while [ ! -f \"$1\" ]; do i=$((i+1)); [ \"$i\" -lt 100 ] || exit 125; /bin/sleep 0.05; done; shift; exec \"$@\""
                var command = [executable] + plan.arguments
                #if os(macOS)
                command = [SeatbeltProfile.executable] + SeatbeltProfile.arguments(clone: cwd.path,
                    scratch: environment["TMPDIR"]!, runHome: home.path,
                    realHome: inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                    repository: nil, cli: executable, mcpPort: nil, command: command)
                #endif
                let handle = try ProcessGroup.spawn(executable: "/bin/sh", arguments: ["-c", launcher, "kaban-probe", gate] + command,
                    workingDirectory: cwd.path, environment: environment, standardOutput: record.directory + "/out", standardError: record.directory + "/err")
                record.handlePID = handle.pid; record.birth = handle.birth
                do {
                    try database.write { try Self.saveProbeProcess(record, db: $0) }
                    try Data().write(to: URL(fileURLWithPath: gate), options: .atomic)
                } catch {
                    _ = try? ProcessGroup.stop(pid: handle.pid, processGroup: handle.processGroup, birth: handle.birth)
                    throw error
                }
            } catch {
                try finishModelProbe(record, outcome: nil, at: at)
                throw error
            }
            try pollModelProbe(record, at: at)
        }
    }

    static func unknownUsageScope(_ flag: SchedulerFlag) -> String? {
        switch flag {
        case .usageExhaustedUnknown(nil): "unknown"
        case .poolUsageExhausted(let pool, nil): pool.rawValue
        default: nil
        }
    }

    static func probeModel(_ task: DurableTask, db: Database) throws -> ModelID? {
        // The last run's requested model is immutable even if an override changes while it runs.
        if let run = task.machine.lastRunId,
           let data = try Data.fetchOne(db, sql: "SELECT payload FROM task_detail WHERE task_id = ?", arguments: [task.card.id.rawValue]),
           let model = try decode(StoredDetail.self, data).runs.first(where: { $0.id == run })?.requestedModel { return model }
        return try resolvedModel(taskId: task.card.id, stageId: task.machine.stageId, db: db)
    }

    private func pollModelProbe(_ record: ModelProbeProcess, at: Date) throws {
        if record.observed { try finishModelProbe(record, outcome: record.outcome, at: at); return }
        guard record.handlePID > 1 else {
            // Crash between reservation and spawn. The throttled reservation is retained; no task is charged.
            try finishModelProbe(record, outcome: nil, at: at)
            return
        }
        var code = ProcessGroup.poll(record.handlePID)
        let live = ProcessGroup.isExecuting(record.handlePID, birth: record.birth)
        if code == nil && !live {
            // The child can exit between WNOHANG and the liveness check. Reap that exit
            // before treating its status as lost after restart; otherwise a clean probe is discarded.
            code = ProcessGroup.poll(record.handlePID)
            if code == nil && ProcessGroup.birth(record.handlePID) == record.birth && ProcessGroup.isAlive(record.handlePID) { return }
        }
        let oversized = ["out", "err"].contains { name in
            (((try? FileManager.default.attributesOfItem(atPath: record.directory + "/" + name)[.size]) as? NSNumber)?.intValue ?? 0) > 65_536
        }
        if live && code == nil && at < record.deadline && !oversized { return }
        if live {
            _ = try ProcessGroup.stop(pid: record.handlePID, processGroup: record.handlePID, birth: record.birth)
            _ = ProcessGroup.poll(record.handlePID)
            if ProcessGroup.isExecuting(record.handlePID, birth: record.birth) { return }
        }
        let output = Self.probeText(record.directory + "/out")
        let error = Self.probeText(record.directory + "/err")
        let outcome: ProbeOutcome?
        if oversized || (live && (at >= record.deadline || code == nil)) { outcome = nil }
        else { outcome = Self.probeOutcome(stdout: output, stderr: error, code: code, model: record.model, pool: record.pool, catalog: record.catalog) }
        var observed = record; observed.observed = true; observed.outcome = outcome
        observed.resetAt = CursorLimitClassifier.resetDate(in: output + error)
        try database.write { try Self.saveProbeProcess(observed, db: $0) }
        try finishModelProbe(observed, outcome: outcome, at: at)
    }

    private static func probeText(_ path: String) -> String {
        guard let file = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? file.close() }
        return String(decoding: (try? file.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
    }

    static func probeOutcome(stdout: String, stderr: String, code: Int32?, model: ModelID, pool: ModelPool, catalog: [ModelInfo]) -> ProbeOutcome? {
        switch CursorLimitClassifier.classify(CursorLimitClassifier.failureText(stdout: stdout, stderr: stderr), pool: pool) {
        case .rateLimit: return .rateLimit
        case .usageExhausted(let pool): return .usageExhausted(pool)
        case .modelUnavailable: return .modelUnavailable
        case .runnerAuth: return .runnerAuth
        default: break
        }
        if CursorRunner.loginFailure(in: stdout + "\n" + stderr) != nil { return .runnerAuth }
        var parser = CursorStreamParser()
        let batch = parser.append(Data((stdout + "\n").utf8))
        var confirmed = false, success = false
        guard code == 0, batch.diagnostics.isEmpty else { return nil }
        for event in batch.events {
            switch event {
            case .initialized(let actual, _):
                guard ModelCatalogMatcher.observe(requestedId: model, actualName: actual, rows: catalog) == .confirmed else { return nil }
                confirmed = true
            case .result(let ok, _): guard ok && confirmed else { return nil }; success = true
            case .error: return nil
            case .toolCall, .toolResult: return nil
            default: break
            }
        }
        return confirmed && success ? .clean : nil
    }

    private func finishModelProbe(_ record: ModelProbeProcess, outcome: ProbeOutcome?, at: Date) throws {
        try database.write { db in
            guard let current = try Self.probeProcesses(db).first(where: { $0.model == record.model }), current.id == record.id, !current.finished else { return }
            let commandId = record.id
            let previousFlags = try Self.schedulerFlags(db)
            var inputs = try Self.schedulerInputs(db)
            if outcome == .clean {
                if let flag = record.modelFlag { inputs.modelFlags.removeAll { $0 == flag } }
                let generations = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT scope, generation FROM usage_probe_due").map { ($0["scope"] as String, $0["generation"] as String) })
                inputs.flags.removeAll { flag in
                    guard record.usageFlags.contains(flag), let scope = Self.unknownUsageScope(flag) else { return false }
                    return generations[scope] == record.usageGenerations[scope]
                }
                for flag in record.usageFlags where !inputs.flags.contains(flag) {
                    if let scope = Self.unknownUsageScope(flag) { try db.execute(sql: "DELETE FROM usage_probe_due WHERE scope = ?", arguments: [scope]) }
                }
            } else {
                switch outcome {
                case .rateLimit: try Self.installLimitEffect(.raiseRateLimit, at: at, db: db)
                case .usageExhausted(let pool):
                    try Self.installLimitEffect(.raiseUsageExhausted(pool), at: at, db: db)
                    if let date = record.resetAt {
                        try Self.replaceUsageReset(date, pool: pool, db: db)
                    }
                case .modelUnavailable: try Self.installUnavailable(modelId: record.model, requested: record.model.rawValue, at: at, db: db)
                case .runnerAuth: try Self.installLimitEffect(.raiseRunnerUnavailable(.runnerAuth), at: at, db: db)
                default: break
                }
                inputs = try Self.schedulerInputs(db)
            }
            for index in inputs.modelFlags.indices where inputs.modelFlags[index].modelId == record.model { inputs.modelFlags[index].lastProbeAt = record.startedAt }
            try db.execute(sql: "UPDATE scheduler_inputs SET payload = ? WHERE id = 1", arguments: [try Self.encode(inputs)])
            if let outcome {
                // One external observation installs limits once, then fans out reducer transitions atomically.
                for (taskId, run) in record.waiters.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    let task = try Self.task(taskId, db: db)
                    guard task.machine.state == .retryWait(.silentExit), task.machine.lastRunId == run else { continue }
                    let command = DurableTaskCommand.probeFinished(outcome)
                    let request = try Self.encode(Request(kind: "transition", taskId: taskId, body: Self.encode(command)))
                    _ = try Self.apply(command, taskId: taskId, commandId: UUID(), at: at, request: request, db: db, installLimitEffects: false)
                }
            }
            try Self.recordChangedSchedulerFlags(from: previousFlags, commandId: commandId, at: at, db: db)
            _ = try Self.journal(.settingsChanged(try Self.modelSettingsChange(key: "model_probe", value: outcome == .clean ? "clean" : "unconfirmed_or_limited", db: db)), projectId: nil, commandId: commandId, at: at, db: db)
            var finished = record; finished.finished = true; finished.outcome = outcome
            try Self.saveProbeProcess(finished, db: db)
        }
        // Raw CLI output is short-lived; only typed outcomes and process identity remain durable.
        try? FileManager.default.removeItem(atPath: record.directory)
    }
}
