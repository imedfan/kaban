import Foundation
import GRDB
import KabanKit
import KabanProtocol

private struct ProjectOperation: Codable {
    let envelope: CommandEnvelope
    let record: ProjectRecord
    let template: LocalGitRepository.TemplateCommit?
    let at: Date
}

extension KabanStore {
    static func migrateProjects(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE project_path (project_id TEXT PRIMARY KEY NOT NULL REFERENCES project(id), path TEXT UNIQUE NOT NULL, repository_id TEXT UNIQUE NOT NULL)")
        try db.execute(sql: "CREATE TABLE removed_project (project_id TEXT PRIMARY KEY NOT NULL REFERENCES project(id), removed_at REAL NOT NULL)")
        try db.execute(sql: "CREATE TABLE project_operation (id TEXT PRIMARY KEY NOT NULL, request BLOB NOT NULL, project_id TEXT UNIQUE NOT NULL, path TEXT UNIQUE NOT NULL, repository_id TEXT UNIQUE NOT NULL, payload BLOB NOT NULL)")
    }
    static func isProjectOperation(_ command: Command) -> Bool {
        switch command {
        case .addProject, .removeProject, .relinkProject, .listBranches, .detectGates, .recheck(.project): true
        default: false
        }
    }
    func executeProjectOperation(_ envelope: CommandEnvelope, now: () -> Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        let intent: ProjectOperation?
        do { intent = try database.read { db -> ProjectOperation? in
            guard let row = try Row.fetchOne(db, sql: "SELECT request, payload FROM project_operation WHERE id = ?", arguments: [envelope.commandId.uuidString]) else { return nil }
            guard (row["request"] as Data) == request else { throw StoreError.commandIdConflict }
            return try Self.decode(ProjectOperation.self, row["payload"])
        }
        } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
        if let intent { return try finishProjectOperation(intent) }
        do {
            if let replay = try database.read({ db in try Self.wireReplay(envelope.commandId, request: request, db: db) }) { return replay }
        } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
        guard envelope.protocolVersion == KabanCoding.protocolVersion else {
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        do {
            switch envelope.command {
            case .listBranches(let id), .detectGates(let id):
                let record = try database.read { db in try Self.project(id, db: db) }
                let repository = try LocalGitRepository(path: record.summary.path)
                let result: CommandResult
                if case .listBranches = envelope.command { result = .branches(try repository.branches()) }
                else { result = .gates(try repository.gates()) }
                return .init(commandId: envelope.commandId, seq: nil, result: result)
            case .removeProject(let id):
                return try database.write { db in
                    _ = try Self.project(id, db: db)
                    let at = now(), previousFlags = try Self.schedulerFlags(db)
                    // Keep durable history and enqueue cancellation/archival effects before hiding the project.
                    for task in try Self.allTasks(db) where task.card.projectId == id && ![.done, .cancelled].contains(task.machine.state.status) {
                        let command = DurableTaskCommand.cancel(keepBranch: true), childId = UUID()
                        let child = try Self.encode(Request(kind: "transition", taskId: task.card.id, body: Self.encode(command)))
                        _ = try Self.apply(command, taskId: task.card.id, commandId: childId, at: at, request: child, db: db)
                    }
                    try db.execute(sql: "INSERT INTO removed_project(project_id, removed_at) VALUES (?, ?)", arguments: [id.rawValue, at.timeIntervalSince1970])
                    try db.execute(sql: "DELETE FROM project_path WHERE project_id = ?", arguments: [id.rawValue])
                    try db.execute(sql: "DELETE FROM scheduler_pause WHERE scope = ?", arguments: [Self.pauseScope(id)])
                    _ = try Self.journal(.projectRemoved(id), projectId: id, commandId: envelope.commandId, at: at, db: db)
                    try Self.recordChangedSchedulerFlags(from: previousFlags, commandId: envelope.commandId, at: at, db: db)
                    let reply = CommandReply(commandId: envelope.commandId, seq: try Self.seq(db), result: .ok)
                    try Self.saveProjectReply(reply, request: request, db: db)
                    return reply
                }
            case .addProject(let path, let createTemplate, let explicit):
                let repository = try LocalGitRepository(path: path)
                try checkProjectPath(repository.path, repositoryID: repository.repositoryID, excluding: nil)
                let identity: GitIdentity
                do { identity = try GitIdentity.resolveForProject(explicit: explicit, repositoryPath: repository.path) }
                catch let error as GitIdentityRequired { throw error.commandError }
                let yaml: String?
                let sourceError: CommandError?
                do { yaml = try repository.pipeline(); sourceError = nil }
                catch let error as CommandError where ["pipeline_invalid", "git_operation_limit"].contains(error.code) { yaml = nil; sourceError = error }
                let template = yaml == nil && sourceError == nil && createTemplate ? try repository.prepareTemplate(identity: identity, commandId: envelope.commandId) : nil
                let id = ProjectID(rawValue: UUID().uuidString.lowercased())
                let summary = ProjectSummary(id: id, name: URL(fileURLWithPath: repository.path).lastPathComponent,
                                             path: repository.path, mascotSeed: id.rawValue, identity: identity)
                var record = Self.productionRecord(summary, repositoryID: repository.repositoryID, yaml: template == nil ? yaml : PipelineTemplate.defaultYAML)
                if let sourceError {
                    record.production?.unavailableReason = .pipelineInvalid
                    record.production?.pipelineSummary.issues = [.init(path: ".kaban/pipeline.yaml", code: sourceError.code, message: sourceError.message, severity: .error)]
                }
                let operation = ProjectOperation(envelope: envelope, record: record, template: template, at: now())
                try saveProjectOperation(operation, request: request)
                return try finishProjectOperation(operation)
            case .relinkProject(let id, let path):
                var record = try database.read { db in try Self.project(id, db: db) }
                guard record.production != nil else { throw CommandError(code: "unsupported_command", message: "Переподключение доступно для локальных проектов.") }
                let repository = try LocalGitRepository(path: path)
                try checkProjectPath(repository.path, repositoryID: repository.repositoryID, excluding: id)
                record.summary.path = repository.path; record.summary.availability = .available
                record.production?.repositoryID = repository.repositoryID
                let operation = ProjectOperation(envelope: envelope, record: record, template: nil, at: now())
                try saveProjectOperation(operation, request: request)
                return try finishProjectOperation(operation)
            case .recheck(.project(let id)):
                let observed = try database.read { db in try Self.project(id, db: db) }
                guard observed.production != nil else { throw CommandError(code: "unsupported_command", message: "Проверка папки доступна для локальных проектов.") }
                let availability = Self.locationAvailability(observed.summary.path)
                return try database.write { db in
                    let previousFlags = try Self.schedulerFlags(db)
                    var record = try Self.project(id, db: db)
                    guard record.summary.path == observed.summary.path else { throw CommandError(code: "project_changed", message: "Путь изменился; повторите проверку.") }
                    record.summary.availability = availability
                    _ = try Self.saveUpdatedProject(record, commandId: envelope.commandId, at: now(), db: db)
                    try Self.recordChangedSchedulerFlags(from: previousFlags, commandId: envelope.commandId, at: now(), db: db)
                    let reply = CommandReply(commandId: envelope.commandId, seq: try Self.seq(db), result: .ok)
                    try Self.saveProjectReply(reply, request: request, db: db)
                    return reply
                }
            default: preconditionFailure("Not a project operation")
            }
        } catch let error as CommandError {
            // A prepared external operation keeps its intent on failure and is reconciled on retry.
            if try database.read({ db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project_operation WHERE id = ?)", arguments: [envelope.commandId.uuidString]) }) == true { throw error }
            let reply = CommandReply(commandId: envelope.commandId, seq: nil, result: .error(error))
            if case .listBranches = envelope.command { return reply }
            if case .detectGates = envelope.command { return reply }
            return try database.write { db in try Self.saveProjectReply(reply, request: request, db: db); return reply }
        } catch let error as StoreError {
            if try database.read({ db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM project_operation WHERE id = ?)", arguments: [envelope.commandId.uuidString]) }) == true { throw error }
            let reply = Self.failure(error, commandId: envelope.commandId)
            if case .listBranches = envelope.command { return reply }
            if case .detectGates = envelope.command { return reply }
            return try database.write { db in try Self.saveProjectReply(reply, request: request, db: db); return reply }
        }
    }
    private static func productionRecord(_ summary: ProjectSummary, repositoryID: String, yaml: String?) -> ProjectRecord {
        let validation = yaml.map { PipelineValidator.validate(yaml: $0) }
        // A readable entry queue stores Backlog even while other stages are invalid. Malformed/missing
        // YAML has an explicitly invalid Backlog-only storage projection, never a fake executable pipeline.
        let pipeline = validation?.config.flatMap { $0.entryStage == nil ? nil : $0 } ?? PipelineConfig(stages: [StageConfig(id: "backlog", name: "Backlog", kind: .queue)])
        let issues = validation?.issues ?? [.init(path: ".kaban/pipeline.yaml", code: "pipeline_missing", message: "Нет закоммиченного пайплайна.", severity: .error)]
        let hash = yaml.map(PipelineContentHash.sha256)
        let projected = pipeline.summary(projectId: summary.id, versionHash: validation?.isValid == true ? hash : nil, issues: issues)
        return ProjectRecord(summary: summary, pipeline: pipeline, version: hash ?? "",
                             production: ProductionProject(repositoryID: repositoryID, pipelineSummary: projected, unavailableReason: yaml == nil ? .noPipeline : (validation?.isValid == true ? nil : .pipelineInvalid)))
    }
    private func checkProjectPath(_ path: String, repositoryID: String, excluding: ProjectID?) throws {
        try database.read { db in
            let exists = try String.fetchOne(db, sql: "SELECT project_id FROM project_path WHERE path = ? OR repository_id = ?", arguments: [path, repositoryID])
            let pending = try String.fetchOne(db, sql: "SELECT project_id FROM project_operation WHERE path = ? OR repository_id = ?", arguments: [path, repositoryID])
            if [exists, pending].compactMap({ $0 }).contains(where: { $0 != excluding?.rawValue }) {
                throw CommandError(code: "project_already_registered", message: "Этот репозиторий уже подключён или подключается.")
            }
        }
    }
    private func saveProjectOperation(_ operation: ProjectOperation, request: Data) throws {
        try database.write { db in
            if try Self.wireReplay(operation.envelope.commandId, request: request, db: db) != nil { throw StoreError.commandIdConflict }
            if let row = try Row.fetchOne(db, sql: "SELECT id FROM project_operation WHERE path = ? OR project_id = ? OR repository_id = ?", arguments: [operation.record.summary.path, operation.record.summary.id.rawValue, operation.record.production!.repositoryID]) {
                throw CommandError(code: "project_already_registered", message: "Репозиторий уже подключается.", params: ["pendingCommandId": row["id"]])
            }
            let owner = try String.fetchOne(db, sql: "SELECT project_id FROM project_path WHERE path = ? OR repository_id = ?", arguments: [operation.record.summary.path, operation.record.production!.repositoryID])
            guard owner == nil || owner == operation.record.summary.id.rawValue else { throw CommandError(code: "project_already_registered", message: "Репозиторий уже подключён.") }
            try db.execute(sql: "INSERT INTO project_operation(id, request, project_id, path, repository_id, payload) VALUES (?, ?, ?, ?, ?, ?)", arguments: [operation.envelope.commandId.uuidString, request, operation.record.summary.id.rawValue, operation.record.summary.path, operation.record.production!.repositoryID, try Self.encode(operation)])
        }
    }
    private func finishProjectOperation(_ operation: ProjectOperation) throws -> CommandReply {
        let repository = try LocalGitRepository(path: operation.record.summary.path)
        if let template = operation.template {
            do { try repository.finishTemplate(template) }
            catch let error as CommandError where ["git_race", "template_conflict"].contains(error.code) {
                // Refusal before (or after a user rewind of) our ref update: retain all user files,
                // release the reservation and durably acknowledge the failed original envelope.
                let reply = CommandReply(commandId: operation.envelope.commandId, seq: nil, result: .error(error))
                return try database.write { db in
                    try Self.saveProjectReply(reply, request: Self.encode(operation.envelope), db: db)
                    try db.execute(sql: "DELETE FROM project_operation WHERE id = ?", arguments: [operation.envelope.commandId.uuidString])
                    return reply
                }
            }
        }
        var refreshed: ProjectRecord?
        if case .addProject = operation.envelope.command {
            do { refreshed = Self.productionRecord(operation.record.summary, repositoryID: repository.repositoryID, yaml: try repository.pipeline()) }
            catch let error as CommandError where ["pipeline_invalid", "git_operation_limit"].contains(error.code) {
                var record = Self.productionRecord(operation.record.summary, repositoryID: repository.repositoryID, yaml: nil)
                record.production?.unavailableReason = .pipelineInvalid
                record.production?.pipelineSummary.issues = [.init(path: ".kaban/pipeline.yaml", code: error.code, message: error.message, severity: .error)]
                refreshed = record
            }
        }
        if refreshed != nil { refreshed?.production?.pipelineSummary.hasUncommittedEdits = try repository.hasConfigurationEdits() }
        return try database.write { db in
            let envelope = operation.envelope, request = try Self.encode(envelope), previousFlags = try Self.schedulerFlags(db)
            let previousLoads = try Self.stageLoads(db)
            var record = refreshed ?? operation.record
            let added: Bool
            if case .addProject = envelope.command { added = true }
            else {
                added = false
                var current = try Self.project(record.summary.id, db: db)
                current.summary.path = record.summary.path; current.summary.availability = record.summary.availability
                current.production?.repositoryID = record.production?.repositoryID ?? repository.repositoryID
                record = current
            }
            try db.execute(sql: "INSERT INTO project(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [record.summary.id.rawValue, try Self.encode(record)])
            try db.execute(sql: "INSERT INTO project_path(project_id, path, repository_id) VALUES (?, ?, ?) ON CONFLICT(project_id) DO UPDATE SET path = excluded.path, repository_id = excluded.repository_id", arguments: [record.summary.id.rawValue, record.summary.path, record.production!.repositoryID])
            _ = try Self.journal(added ? .projectAdded(record.summary) : .projectUpdated(record.summary), projectId: record.summary.id, commandId: envelope.commandId, at: operation.at, db: db)
            if added {
                _ = try Self.journal(.pipelineApplied(record.projectedPipeline), projectId: record.summary.id, commandId: envelope.commandId, at: operation.at, db: db)
                try Self.recordChangedLoads(from: previousLoads, commandId: envelope.commandId, at: operation.at, db: db)
            }
            try Self.recordChangedSchedulerFlags(from: previousFlags, commandId: envelope.commandId, at: operation.at, db: db)
            let reply = CommandReply(commandId: envelope.commandId, seq: try Self.seq(db), result: .ok)
            try Self.saveProjectReply(reply, request: request, db: db)
            try db.execute(sql: "DELETE FROM project_operation WHERE id = ?", arguments: [envelope.commandId.uuidString])
            return reply
        }
    }
    private static func saveProjectReply(_ reply: CommandReply, request: Data, db: Database) throws {
        try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [reply.commandId.uuidString, request, try Self.encode(reply)])
    }
    /// Startup resumes durable intents. Unavailable/conflicting repositories retain their intent;
    /// independent registrations still recover, and retry of the original envelope reports the refusal.
    public func recoverProjectOperations() throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let pending = try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM project_operation ORDER BY rowid").map { try Self.decode(ProjectOperation.self, $0) } }
        for operation in pending { _ = try? finishProjectOperation(operation) }
    }
    private static func locationAvailability(_ path: String) -> ProjectSummary.Availability {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        return exists && directory.boolValue && FileManager.default.fileExists(atPath: path + "/.git") ? .available : .missing
    }
    /// Bounded host observer: filesystem checks outside SQLite, unchanged observations emit no events.
    public func refreshProjectLocations(at: Date = Date(), commandId: CommandID = UUID(), only: ProjectID? = nil) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        let records = try database.read { db in try Self.projects(db).filter { $0.production != nil && (only == nil || $0.summary.id == only) } }
        let observations = records.map { record -> (ProjectRecord, ProjectSummary.Availability) in
            return (record, Self.locationAvailability(record.summary.path))
        }
        try database.write { db in
            let previousFlags = try Self.schedulerFlags(db)
            for (observed, availability) in observations {
                var current = try Self.project(observed.summary.id, db: db)
                guard current.summary.path == observed.summary.path, current.summary.availability != availability else { continue }
                current.summary.availability = availability
                _ = try Self.saveUpdatedProject(current, commandId: commandId, at: at, db: db)
            }
            try Self.recordChangedSchedulerFlags(from: previousFlags, commandId: commandId, at: at, db: db)
        }
    }
}
