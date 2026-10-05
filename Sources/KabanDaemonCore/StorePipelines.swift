import Foundation
import GRDB
import KabanKit
import KabanProtocol

struct PipelineVersion: Codable, Hashable, Sendable {
    let hash: String
    let pipeline: PipelineConfig
    let source: PipelineSource
}
private struct PipelineOperation: Codable {
    let envelope: CommandEnvelope
    let projectId: ProjectID
    let path: String
    let repositoryID: String
    let plan: LocalGitRepository.PipelineCommit
    let at: Date
}

extension KabanStore {
    static func migratePipelines(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE pipeline_version (project_id TEXT NOT NULL REFERENCES project(id), hash TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(project_id, hash))")
        try db.execute(sql: "CREATE TABLE pipeline_operation (id TEXT PRIMARY KEY NOT NULL, request BLOB NOT NULL, project_id TEXT UNIQUE NOT NULL REFERENCES project(id), payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE run_spec (run_id TEXT PRIMARY KEY NOT NULL, task_id TEXT NOT NULL REFERENCES task(id), payload BLOB NOT NULL)")
        try db.execute(sql: "CREATE TABLE pipeline_deferred (task_id TEXT PRIMARY KEY NOT NULL REFERENCES task(id), project_id TEXT NOT NULL REFERENCES project(id), stage_id TEXT NOT NULL, run_spec_id TEXT, command BLOB NOT NULL)")
    }
    static func pipelineContext(_ projectId: ProjectID, db: Database) throws -> PipelineValidationContext {
        let tasks = try allTasks(db).filter { $0.card.projectId == projectId && ![.done, .cancelled].contains($0.machine.state.status) }
        let kinds = tasks.reduce(into: [StageID: StageKind]()) { result, task in
            if let stage = task.pipeline.stage(task.machine.stageId) { result[stage.id] = stage.kind }
        }
        return .init(stagesWithActiveTasks: Set(tasks.map { $0.machine.stageId }), activeStageKinds: kinds)
    }
    static func sourceValidation(_ source: PipelineSource, projectId: ProjectID, db: Database) throws -> PipelineValidation {
        guard let file = source.files[".kaban/pipeline.yaml"] else {
            return .init(config: nil, issues: [.init(path: ".kaban/pipeline.yaml", code: "pipeline_missing", message: "Нет закоммиченного пайплайна.", severity: .error)])
        }
        guard file.data.count <= DaemonWire.maxPipelineBytes, let yaml = source.yaml else {
            return .init(config: nil, issues: [.init(path: ".kaban/pipeline.yaml", code: "pipeline_invalid", message: "pipeline.yaml должен быть UTF-8 размером не более 1 МиБ.", severity: .error)])
        }
        return PipelineValidator.validate(yaml: yaml, context: try pipelineContext(projectId, db: db))
    }
    static func rememberPipelineVersion(_ source: PipelineSource, hash: String, pipeline: PipelineConfig, projectId: ProjectID, db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pipeline_version WHERE project_id = ? AND hash = ?)", arguments: [projectId.rawValue, hash]) != true {
            let version = PipelineVersion(hash: hash, pipeline: pipeline, source: source)
            try db.execute(sql: "INSERT INTO pipeline_version(project_id, hash, payload) VALUES (?, ?, ?)", arguments: [projectId.rawValue, hash, try encode(version)])
        }
    }
    static func applyPipelineSource(_ source: PipelineSource, edits: Bool, record: inout ProjectRecord, db: Database) throws {
        let validation = try sourceValidation(source, projectId: record.summary.id, db: db)
        let sameAssets = record.production?.source?.files == source.files && record.production?.source?.referencedSkills == source.referencedSkills
        let sourceHash = sameAssets && record.projectedPipeline.sourceHash != nil ? record.projectedPipeline.sourceHash! : try source.versionHash()
        let hash = source.files[".kaban/pipeline.yaml"] == nil ? nil : sourceHash
        let previous = record.pipeline
        let config = validation.config ?? previous
        // The committed invalid config is visible, but orphaned nonterminal cards retain their
        // storage lanes until the human restores/moves them. No last-valid execution fallback.
        let active = try pipelineContext(record.summary.id, db: db).stagesWithActiveTasks
        var storage = config.entryStage == nil ? previous : config
        for id in active where storage.stage(id) == nil {
            if let stage = previous.stage(id) { storage.stages.append(stage) }
        }
        record.pipeline = storage; record.version = hash ?? ""
        record.production?.source = source
        record.production?.unavailableReason = source.files[".kaban/pipeline.yaml"] == nil ? .noPipeline : (validation.isValid ? nil : .pipelineInvalid)
        record.production?.pipelineSummary = storage.summary(projectId: record.summary.id, versionHash: validation.isValid ? hash : nil, issues: validation.issues, hasUncommittedEdits: edits)
        record.production?.pipelineSummary.sourceHash = sourceHash
        if validation.isValid, let hash, let config = validation.config {
            try rememberPipelineVersion(source, hash: hash, pipeline: config, projectId: record.summary.id, db: db)
        }
    }
    static func applyUncommittedValidation(_ file: PipelineSource.File?, error: CommandError?, record: inout ProjectRecord, db: Database) throws {
        guard record.projectedPipeline.hasUncommittedEdits else { record.production?.pipelineSummary.uncommittedIssues = nil; return }
        if let error {
            record.production?.pipelineSummary.uncommittedIssues = [.init(path: ".kaban/pipeline.yaml", code: error.code, message: error.message, severity: .error)]
        } else {
            let source = PipelineSource(commit: "", files: file.map { [".kaban/pipeline.yaml": $0] } ?? [:])
            record.production?.pipelineSummary.uncommittedIssues = try sourceValidation(source, projectId: record.summary.id, db: db).issues
        }
    }

    /// Reads Git outside SQLite. Only production records are observed; fake fixtures never gain
    /// the production validator's approval by passing through this path.
    public func refreshPipelines(at: Date = Date(), commandId: CommandID = UUID(), only: ProjectID? = nil) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let records = try database.read { db in try Self.projects(db).filter { record in
            record.production != nil && record.summary.availability == .available && (only == nil || record.summary.id == only)
        } }
        for observed in records {
            let pending = try database.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pipeline_operation WHERE project_id = ? UNION ALL SELECT 1 FROM project_operation WHERE project_id = ?)", arguments: [observed.summary.id.rawValue, observed.summary.id.rawValue]) }
            if pending == true { continue }
            var source: PipelineSource?, sourceError: CommandError?
            var edits = observed.projectedPipeline.hasUncommittedEdits
            var workingFile: PipelineSource.File?, workingError: CommandError?
            do {
                let repository = try LocalGitRepository(path: observed.summary.path)
                guard repository.repositoryID == observed.production?.repositoryID else { throw CommandError(code: "repository_changed", message: "По сохранённому пути находится другой репозиторий.") }
                let commit = try repository.mainCommit()
                source = observed.production?.source?.commit == commit ? observed.production?.source : try repository.pipelineSource()
                edits = try repository.hasConfigurationEdits(); sourceError = nil
                if edits {
                    do { workingFile = try repository.workingPipelineFile() }
                    catch let error as CommandError { workingError = error }
                }
            } catch let error as CommandError {
                if error.code == "project_missing" { continue }
                source = nil; edits = observed.projectedPipeline.hasUncommittedEdits; sourceError = error
            }
            try database.write { db in
                var current = try Self.project(observed.summary.id, db: db)
                guard current.summary.path == observed.summary.path, current.production?.repositoryID == observed.production?.repositoryID else { return }
                let flags = try Self.schedulerFlags(db), loads = try Self.stageLoads(db), previous = current.projectedPipeline
                let previousSource = current.production?.source, previousPipeline = current.pipeline, previousReason = current.production?.unavailableReason
                if let source { try Self.applyPipelineSource(source, edits: edits, record: &current, db: db) }
                else if let sourceError {
                    current.production?.unavailableReason = .pipelineInvalid
                    current.production?.pipelineSummary.versionHash = nil
                    current.production?.pipelineSummary.sourceHash = nil
                    current.production?.pipelineSummary.issues = [.init(path: ".kaban/", code: sourceError.code, message: sourceError.message, severity: .error, params: sourceError.params)]
                }
                try Self.applyUncommittedValidation(workingFile, error: workingError, record: &current, db: db)
                if previous != current.projectedPipeline || previousSource != current.production?.source || previousPipeline != current.pipeline || previousReason != current.production?.unavailableReason {
                    try db.execute(sql: "UPDATE project SET payload = ? WHERE id = ?", arguments: [try Self.encode(current), current.summary.id.rawValue])
                }
                if previous != current.projectedPipeline {
                    _ = try Self.journal(.pipelineApplied(current.projectedPipeline), projectId: current.summary.id, commandId: commandId, at: at, db: db)
                }
                try Self.recordChangedLoads(from: loads, commandId: commandId, at: at, db: db)
                try Self.recordChangedSchedulerFlags(from: flags, commandId: commandId, at: at, db: db)
                if current.production?.unavailableReason == nil { try Self.resumePipelineTransitions(current.summary.id, at: at, db: db) }
            }
        }
    }

    func executePipelineUpdate(_ envelope: CommandEnvelope, now: () -> Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        do {
            if let pending = try database.read({ db -> PipelineOperation? in
                guard let row = try Row.fetchOne(db, sql: "SELECT request, payload FROM pipeline_operation WHERE id = ?", arguments: [envelope.commandId.uuidString]) else { return nil }
                guard (row["request"] as Data) == request else { throw StoreError.commandIdConflict }
                return try Self.decode(PipelineOperation.self, row["payload"])
            }) { return try finishPipelineOperation(pending) }
            if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
        guard envelope.protocolVersion == KabanCoding.protocolVersion else {
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        do {
            guard case .updatePipeline(let id, let hash, let draft) = envelope.command else { preconditionFailure() }
            guard let draft else { throw CommandError(code: "pipeline_draft_required", message: "Передайте точный YAML и базовую версию в draft.") }
            var record = try database.read { try Self.project(id, db: $0) }
            if record.production != nil {
                try refreshPipelines(only: id)
                record = try database.read { try Self.project(id, db: $0) }
            }
            try draft.checkBinding(projectId: id, currentVersionHash: record.projectedPipeline.versionHash, requestedHash: hash)
            guard record.production != nil else { throw CommandError(code: CommandError.unsupportedCommandCode, message: "Применение пайплайна доступно для локальных проектов.") }
            try draft.checkSourceBinding(currentSourceHash: record.projectedPipeline.sourceHash, emptySourceHash: record.production?.source?.files.isEmpty == true ? record.projectedPipeline.sourceHash : nil)
            let validation = try database.read { try Self.validateDraftContent(projectId: id, content: draft.content, db: $0) }
            guard validation.isValid else { return try savePipelineReply(.init(commandId: envelope.commandId, seq: nil, result: .validationIssues(validation.issues)), request: request) }
            let repository = try LocalGitRepository(path: record.summary.path)
            guard repository.repositoryID == record.production?.repositoryID else { throw CommandError(code: "repository_changed", message: "По сохранённому пути находится другой репозиторий.") }
            let source = try repository.pipelineSource()
            try draft.checkSourceBinding(currentSourceHash: source.versionHash(), emptySourceHash: source.files.isEmpty ? source.versionHash() : nil)
            guard let identity = record.summary.identity else { throw GitIdentityRequired(missing: [.name, .email]).commandError }
            let plan = try repository.preparePipeline(content: draft.content, source: source, identity: identity, commandId: envelope.commandId)
            let operation = PipelineOperation(envelope: envelope, projectId: id, path: repository.path, repositoryID: repository.repositoryID, plan: plan, at: now())
            try database.write { db in
                _ = try Self.project(id, db: db)
                if try Self.wireReplay(envelope.commandId, request: request, db: db) != nil { throw StoreError.commandIdConflict }
                try Self.requirePipelineIdle(id, db: db)
                let valid = try Self.validateDraftContent(projectId: id, content: draft.content, db: db)
                guard valid.isValid else { throw StoreError.invalidPipeline }
                try db.execute(sql: "INSERT INTO pipeline_operation(id, request, project_id, payload) VALUES (?, ?, ?, ?)", arguments: [envelope.commandId.uuidString, request, id.rawValue, try Self.encode(operation)])
            }
            return try finishPipelineOperation(operation)
        } catch let error as CommandError {
            if try hasPipelineIntent(envelope.commandId) { throw error }
            return try savePipelineReply(.init(commandId: envelope.commandId, seq: nil, result: .error(error)), request: request)
        } catch let error as StoreError {
            if try hasPipelineIntent(envelope.commandId) { throw error }
            return try savePipelineReply(Self.failure(error, commandId: envelope.commandId), request: request)
        }
    }
    static func requireNoProjectIntent(_ id: ProjectID, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pipeline_operation WHERE project_id = ? UNION ALL SELECT 1 FROM project_operation WHERE project_id = ?)", arguments: [id.rawValue, id.rawValue]) != true else {
            throw StoreError.rejected(.init(code: "project_operation_pending", message: "Сначала завершите предыдущую операцию проекта."))
        }
    }
    static func requirePipelineIdle(_ id: ProjectID, db: Database) throws {
        try requireNoProjectIntent(id, db: db)
        let merging = try allTasks(db).contains { $0.card.projectId == id && $0.pipeline.stage($0.machine.stageId)?.kind == .merge && $0.machine.state.status.occupiesWIP }
        guard !merging else { throw CommandError(code: "merge_in_progress", message: "Дождитесь завершения слияния перед применением пайплайна.") }
    }
    private func hasPipelineIntent(_ id: CommandID) throws -> Bool {
        try database.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM pipeline_operation WHERE id = ?)", arguments: [id.uuidString]) == true }
    }
    private func savePipelineReply(_ reply: CommandReply, request: Data) throws -> CommandReply {
        try database.write { db in
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [reply.commandId.uuidString, request, try Self.encode(reply)])
            return reply
        }
    }
    private func finishPipelineOperation(_ operation: PipelineOperation) throws -> CommandReply {
        let repository = try LocalGitRepository(path: operation.path)
        guard repository.repositoryID == operation.repositoryID else { throw CommandError(code: "repository_changed", message: "Репозиторий ожидающей операции изменился.") }
        do { try repository.finishPipeline(operation.plan) }
        catch let error as CommandError where ["git_race", "pipeline_checkout_required"].contains(error.code) {
            return try database.write { db in
                let reply = CommandReply(commandId: operation.envelope.commandId, seq: nil, result: .error(error))
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [reply.commandId.uuidString, try Self.encode(operation.envelope), try Self.encode(reply)])
                try db.execute(sql: "DELETE FROM pipeline_operation WHERE id = ?", arguments: [reply.commandId.uuidString])
                return reply
            }
        }
        var source: PipelineSource?, sourceError: CommandError?, workingFile: PipelineSource.File?, workingError: CommandError?
        let edits = try repository.hasConfigurationEdits()
        do { source = try repository.pipelineSource() }
        catch let error as CommandError { sourceError = error }
        if edits {
            do { workingFile = try repository.workingPipelineFile() }
            catch let error as CommandError { workingError = error }
        }
        let acceptedHash = try operation.plan.source.versionHash()
        return try database.write { db in
            let flags = try Self.schedulerFlags(db), loads = try Self.stageLoads(db)
            var record = try Self.project(operation.projectId, db: db)
            guard record.summary.path == operation.path, record.production?.repositoryID == operation.repositoryID else { throw StoreError.incompleteProjection }
            // The accepted commit remains an immutable version even if recovery sees a newer,
            // invalid user commit. Publish current main without losing the accepted version.
            guard let yaml = operation.plan.source.yaml else { throw StoreError.incompleteProjection }
            let accepted = PipelineValidator.validate(yaml: yaml)
            guard accepted.isValid, let config = accepted.config else { throw StoreError.incompleteProjection }
            try Self.rememberPipelineVersion(operation.plan.source, hash: acceptedHash, pipeline: config, projectId: operation.projectId, db: db)
            if let source { try Self.applyPipelineSource(source, edits: edits, record: &record, db: db) }
            else if let sourceError {
                record.production?.unavailableReason = .pipelineInvalid
                record.production?.pipelineSummary.versionHash = nil
                record.production?.pipelineSummary.sourceHash = nil
                record.production?.pipelineSummary.hasUncommittedEdits = edits
                record.production?.pipelineSummary.issues = [.init(path: ".kaban/", code: sourceError.code, message: sourceError.message, severity: .error, params: sourceError.params)]
            }
            try Self.applyUncommittedValidation(workingFile, error: workingError, record: &record, db: db)
            try db.execute(sql: "UPDATE project SET payload = ? WHERE id = ?", arguments: [try Self.encode(record), operation.projectId.rawValue])
            _ = try Self.journal(.pipelineApplied(record.projectedPipeline), projectId: operation.projectId, commandId: operation.envelope.commandId, at: operation.at, db: db)
            try Self.recordChangedLoads(from: loads, commandId: operation.envelope.commandId, at: operation.at, db: db)
            try Self.recordChangedSchedulerFlags(from: flags, commandId: operation.envelope.commandId, at: operation.at, db: db)
            try db.execute(sql: "DELETE FROM pipeline_operation WHERE id = ?", arguments: [operation.envelope.commandId.uuidString])
            if record.production?.unavailableReason == nil { try Self.resumePipelineTransitions(operation.projectId, at: operation.at, db: db) }
            let reply = CommandReply(commandId: operation.envelope.commandId, seq: try Self.seq(db), result: .pipelineVersion(hash: acceptedHash))
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [reply.commandId.uuidString, try Self.encode(operation.envelope), try Self.encode(reply)])
            return reply
        }
    }
    public func recoverPipelineOperations() throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let pending = try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM pipeline_operation ORDER BY rowid").map { try Self.decode(PipelineOperation.self, $0) } }
        for operation in pending { _ = try? finishPipelineOperation(operation) }
    }
    static func deferPipelineTransition(_ command: DurableTaskCommand, task: DurableTask, commandId: CommandID, at: Date, request: Data, db: Database) throws -> DurableReceipt {
        try db.execute(sql: "INSERT INTO pipeline_deferred(task_id, project_id, stage_id, run_spec_id, command) VALUES (?, ?, ?, ?, ?) ON CONFLICT(task_id) DO UPDATE SET command = excluded.command",
                       arguments: [task.card.id.rawValue, task.card.projectId.rawValue, task.machine.stageId.rawValue, task.runSpecId?.rawValue, try encode(command)])
        let seq = try journal(.taskUpdated(task.card), task: task, commandId: commandId, at: at, db: db)
        let receipt = DurableReceipt(commandId: commandId, firstSeq: seq, lastSeq: seq, task: task)
        try saveReceipt(receipt, request: request, db: db)
        return receipt
    }
    static func resumePipelineTransitions(_ projectId: ProjectID, at: Date, db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM pipeline_deferred WHERE project_id = ?", arguments: [projectId.rawValue]) {
            let task = try task(TaskID(rawValue: row["task_id"]), db: db)
            let stage: String = row["stage_id"], run: String? = row["run_spec_id"]
            try db.execute(sql: "DELETE FROM pipeline_deferred WHERE task_id = ?", arguments: [task.card.id.rawValue])
            guard task.machine.stageId.rawValue == stage, task.runSpecId?.rawValue == run, task.machine.state.status == .gating else { continue }
            let command = try decode(DurableTaskCommand.self, row["command"]), id = UUID()
            let request = try encode(Request(kind: "transition", taskId: task.card.id, body: encode(command)))
            _ = try apply(command, taskId: task.card.id, commandId: id, at: at, request: request, db: db)
        }
    }
}
