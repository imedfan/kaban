import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    /// Transport-neutral receiver for the existing wire contract. Domain refusals are durable replies;
    /// storage failures throw and roll back projection, journal, outbox and both receipt tables.
    /// The original envelope is compared before clock/ID generation or loading current mutable state.
    public func execute(_ envelope: CommandEnvelope, now: () -> Date = { Date() },
                        makeTaskID: () -> TaskID = { TaskID(rawValue: UUID().uuidString.lowercased()) }) throws -> CommandReply {
        projectOperations.lock(); defer { projectOperations.unlock() }
        if case .restoreWIP = envelope.command { return try executeWIPRestore(envelope, at: now()) }
        if case .updatePipeline = envelope.command { return try executePipelineUpdate(envelope, now: now) }
        if Self.isProjectOperation(envelope.command) { return try executeProjectOperation(envelope, now: now) }
        if case .recheck(.runner) = envelope.command { return try recheckRunner(envelope, at: now()) }
        if case .refreshModelCatalog = envelope.command { return try refreshModelCatalog(envelope, at: now()) }
        if case .setModelOverride(let taskId, let stageId, let model) = envelope.command {
            return try setModelOverride(envelope, taskId: taskId, stageId: stageId, model: model, at: now())
        }
        if case .setModelPoolRule(let pattern, let pool) = envelope.command {
            return try setModelPoolRule(envelope, pattern: pattern, pool: pool, at: now())
        }
        if case .removeModelPoolRule(let pattern) = envelope.command {
            return try removeModelPoolRule(envelope, pattern: pattern, at: now())
        }
        if case .clearModelFlag(let modelId) = envelope.command {
            return try clearModelFlag(envelope, modelId: modelId, at: now())
        }
        if case .resumeAfterRateLimit = envelope.command { return try resumeAfterRateLimit(envelope, at: now()) }
        let request = try Self.encode(envelope)
        let validating: ProjectID?
        switch envelope.command {
        case .validatePipeline(let id, _): validating = id
        case .validatePipelineDraft(let draft): validating = draft.projectId
        default: validating = nil
        }
        if let validating, envelope.protocolVersion == KabanCoding.protocolVersion {
            do {
                if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
            } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
            try refreshPipelines(only: validating)
        }
        return try database.write { db in
            do {
                if let reply = try Self.wireReplay(envelope.commandId, request: request, db: db) { return reply }
            } catch let error as StoreError {
                return Self.failure(error, commandId: envelope.commandId)
            }
            guard envelope.protocolVersion == KabanCoding.protocolVersion else {
                return CommandReply(commandId: envelope.commandId, seq: nil, result: .error(CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
            }
            // Queries must remain fresh and never consume a command identity.
            switch envelope.command {
            case .getTaskDetail(let id):
                do { return CommandReply(commandId: envelope.commandId, seq: nil, result: .taskDetail(try Self.taskDetail(id, db: db))) }
                catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
            case .getRunHistory(let id):
                do {
                    let runs = try Self.runSummaries(id, db: db)
                    try Self.ensureWireFit(runs, code: CommandError.detailTooLargeCode, message: "История запусков не помещается в сообщение.")
                    return CommandReply(commandId: envelope.commandId, seq: nil, result: .runs(runs))
                }
                catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
            case .listModels:
                do {
                    let rows = try Self.catalogRecord(db).rows.filter { !$0.forbidden }.sorted { $0.id.rawValue < $1.id.rawValue }
                    return CommandReply(commandId: envelope.commandId, seq: nil, result: .models(rows))
                } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
            case .validatePipeline(let projectId, let content):
                do {
                    let validation = try Self.validateDraftContent(projectId: projectId, content: content, db: db)
                    return .init(commandId: envelope.commandId, seq: nil, result: validation.commandResult(contentHash: PipelineContentHash.sha256(content)))
                } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
            case .validatePipelineDraft(let draft):
                do {
                    let project = try Self.project(draft.projectId, db: db)
                    try draft.checkBinding(projectId: project.summary.id, currentVersionHash: project.projectedPipeline.versionHash, requestedHash: draft.contentHash)
                    if project.production != nil {
                        try draft.checkSourceBinding(currentSourceHash: project.projectedPipeline.sourceHash, emptySourceHash: project.production?.source?.files.isEmpty == true ? project.projectedPipeline.sourceHash : nil)
                    }
                    let validation = try Self.validateDraftContent(projectId: draft.projectId, content: draft.content, db: db)
                    var result = validation.draftValidation(projectId: draft.projectId, contentHash: draft.contentHash)
                    result.baseVersionHash = project.projectedPipeline.versionHash
                    result.baseSourceHash = project.projectedPipeline.sourceHash
                    return .init(commandId: envelope.commandId, seq: nil, result: .pipelineDraft(result))
                } catch let error as CommandError { return .init(commandId: envelope.commandId, seq: nil, result: .error(error)) }
                catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
            default: break
            }
            var reply: CommandReply?
            do {
                try db.inSavepoint {
                    reply = try Self.dispatch(envelope, request: request, now: now, makeTaskID: makeTaskID, db: db)
                    return .commit
                }
            } catch let error as StoreError {
                reply = Self.failure(error, commandId: envelope.commandId)
            }
            guard let reply else { throw StoreError.incompleteProjection }
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)",
                           arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            return reply
        }
    }

    private static func dispatch(_ envelope: CommandEnvelope, request: Data, now: () -> Date,
                                 makeTaskID: () -> TaskID, db: Database) throws -> CommandReply {
        let id = envelope.commandId
        func ok(_ seq: Seq) -> CommandReply { CommandReply(commandId: id, seq: seq, result: .ok) }
        switch envelope.command {
        case .createTask(let projectId, let title, let body):
            let title = try validTitle(title); try validBody(body)
            let project = try project(projectId, db: db)
            guard let entry = project.pipeline.entryStage else { throw StoreError.invalidPipeline }
            let at = now()
            let card = TaskCard(id: makeTaskID(), projectId: projectId, title: title, stageId: entry.id, state: .queued(nil),
                                hasAcceptanceCriteria: TaskMarkdown.hasAcceptanceCriteria(in: body), updatedAt: at)
            let receipt = try createTask(card: card, pipeline: project.pipeline, commandId: id, at: at, request: request, managed: true, body: body, db: db)
            return CommandReply(commandId: id, seq: receipt.lastSeq, result: .taskCreated(receipt.task.card.id))
        case .editTask(let taskId, let title, let body):
            var task = try managedTask(taskId, db: db)
            guard [.queued, .waitingHuman, .paused].contains(task.machine.state.status) else { throw invalidState("Задачу можно редактировать в очереди, на паузе или в ожидании человека.") }
            guard title != nil || body != nil else { throw invalidRequest("Нет изменений.") }
            var detail = try detail(taskId, db: db)
            if let title { task.card.title = try validTitle(title) }
            if let body {
                guard detail.body != nil else { throw StoreError.incompleteProjection }
                try validBody(body); detail.body = body
                task.card.hasAcceptanceCriteria = TaskMarkdown.hasAcceptanceCriteria(in: body)
            }
            task.card.updatedAt = now()
            try saveDetail(detail, taskId: taskId, db: db)
            return ok(try saveUpdatedTask(task, commandId: id, at: task.card.updatedAt, edited: true, db: db))
        case .setPriority(let taskId, let priority):
            var task = try managedTask(taskId, db: db)
            guard task.machine.state.status != .done, task.machine.state.status != .cancelled else { throw invalidState("Задача уже завершена.") }
            task.card.priority = priority; task.card.updatedAt = now()
            return ok(try saveUpdatedTask(task, commandId: id, at: task.card.updatedAt, db: db))
        case .pauseAll: return ok(try setManualPause(true, projectId: nil, commandId: id, at: now(), db: db))
        case .resumeAll: return ok(try setManualPause(false, projectId: nil, commandId: id, at: now(), db: db))
        case .pauseProject(let projectId): return ok(try setManualPause(true, projectId: projectId, commandId: id, at: now(), db: db))
        case .resumeProject(let projectId): return ok(try setManualPause(false, projectId: projectId, commandId: id, at: now(), db: db))
        case .setMaxConcurrentRuns(let count):
            var settings = try settings(db); settings.maxConcurrentRuns = count
            return ok(try saveWireSettings(settings, commandId: id, at: now(), db: db))
        case .setQuotaOptions(let options):
            var settings = try settings(db)
            let at = now()
            if options.consent && !settings.quotaOptions.consent { settings.quotaConsentedAt = at }
            if !options.consent { settings.quotaConsentedAt = nil }
            settings.quotaOptions = options
            return ok(try saveWireSettings(settings, commandId: id, at: at, db: db))
        case .setMascot(let projectId, let seed):
            var record = try project(projectId, db: db); record.summary.mascotSeed = seed
            return ok(try saveUpdatedProject(record, commandId: id, at: now(), db: db))
        case .setProjectWeight(let projectId, let weight, let maxRuns):
            guard weight > 0, maxRuns.map({ $0 > 0 }) ?? true else { throw invalidRequest("Вес и лимит запусков должны быть положительными.") }
            var record = try project(projectId, db: db); record.summary.weight = weight; record.summary.maxRuns = maxRuns
            // An old weighted turn must not keep credits granted under a larger previous weight.
            var cursor = try decode(SchedulerCursor.self, Data.fetchOne(db, sql: "SELECT payload FROM scheduler_cursor WHERE id = 1")!)
            if cursor.project == projectId {
                cursor.remaining = min(cursor.remaining, weight - 1)
                try db.execute(sql: "UPDATE scheduler_cursor SET payload = ? WHERE id = 1", arguments: [try encode(cursor)])
            }
            return ok(try saveUpdatedProject(record, commandId: id, at: now(), db: db))
        case .setProjectIdentity(let projectId, let identity):
            var record = try project(projectId, db: db)
            do { record.summary.identity = try identity.validated() }
            catch let error as GitIdentityRequired { throw StoreError.rejected(error.commandError) }
            return ok(try saveUpdatedProject(record, commandId: id, at: now(), db: db))
        case .updatePipeline(let projectId, let hash, let draft):
            guard let draft else {
                throw StoreError.rejected(.init(code: "pipeline_draft_required", message: "Передайте точный YAML и базовую версию в draft."))
            }
            let project = try project(projectId, db: db)
            do { try draft.checkBinding(projectId: projectId, currentVersionHash: project.projectedPipeline.versionHash, requestedHash: hash) }
            catch let error as CommandError { throw StoreError.rejected(error) }
            throw StoreError.rejected(.init(code: CommandError.unsupportedCommandCode, message: "Применение пайплайна требует production lifecycle проекта.", params: ["command": envelope.command.name.rawValue]))
        case .allowGitOnce(let denialId):
            return ok(try allowGitOnce(denialId, commandId: id, at: now(), db: db))
        case .addDenialToPolicy(let denialId, let scope):
            return ok(try addDenialToPolicy(denialId, scope: scope, commandId: id, at: now(), db: db))
        case .revokeGitGrant(let grantId):
            return ok(try revokeGitGrant(grantId, commandId: id, at: now(), db: db))
        case .acceptSuspiciousFiles(let taskId, let files):
            _ = try managedTask(taskId, db: db)
            let receipt = try apply(.acceptSuspicious(files), taskId: taskId, commandId: id, at: now(), request: request, db: db)
            guard receipt.firstSeq != nil else { throw invalidState("Команда не изменила состояние задачи.") }
            return ok(receipt.lastSeq)
        case .listIncidents(let projectIds, let state):
            return CommandReply(commandId: id, seq: nil, result: .incidents(try Self.incidents(projectIds: projectIds, state: state, db: db)))
        default:
            guard let (taskId, command) = transitionCommand(envelope.command) else {
                throw StoreError.rejected(CommandError(code: CommandError.unsupportedCommandCode, message: "Команда ещё не поддерживается этим backend.", params: ["command": envelope.command.name.rawValue]))
            }
            let task = try managedTask(taskId, db: db)
            let at = now()
            if case .move(let target) = command { try validateWireMove(task, target: target, at: at, db: db) }
            let receipt = try apply(command, taskId: taskId, commandId: id, at: at, request: request, db: db)
            guard receipt.firstSeq != nil else { throw invalidState("Команда не изменила состояние задачи.") }
            return ok(receipt.lastSeq)
        }
    }

    static func validateDraftContent(projectId: ProjectID, content: String, db: Database) throws -> PipelineValidation {
        _ = try project(projectId, db: db)
        guard content.utf8.count <= DaemonWire.maxPipelineBytes else { throw invalidRequest("Черновик пайплайна превышает лимит размера.") }
        // No fake merge exception. Missing production MCP allowlist is an empty allowlist,
        // so selected external servers produce warnings instead of being silently approved.
        return PipelineValidator.validate(yaml: content, context: try pipelineContext(projectId, db: db))
    }

    private static func transitionCommand(_ command: Command) -> (TaskID, DurableTaskCommand)? {
        switch command {
        case .moveTask(let id, let target): (id, .move(target))
        case .pauseTask(let id): (id, .pause)
        case .resumeTask(let id): (id, .resume)
        case .cancelTask(let id, let keep): (id, .cancel(keepBranch: keep))
        case .retryStage(let id, let grant): (id, .retryStage(grantAttempts: grant))
        case .answerHuman(let id, let text, let request): (id, .answer(text: text, requestId: request))
        case .approve(let id): (id, .approve)
        case .requestChanges(let id, let comments, let target): (id, .requestChanges(comments: comments, target: target))
        case .reject(let id, let target, let keep): (id, .reject(target: target, keepBranch: keep))
        default: nil
        }
    }

    private static func managedTask(_ id: TaskID, db: Database) throws -> DurableTask {
        let task = try task(id, db: db)
        guard try isManaged(id, db: db) else { throw StoreError.incompleteProjection }
        _ = try project(task.card.projectId, db: db)
        return task
    }

    private static func validateWireMove(_ task: DurableTask, target: StageID, at: Date, db: Database) throws {
        guard try project(task.card.projectId, db: db).summary.availability == .available else { throw StoreError.schedulerBlocked }
        guard let source = task.pipeline.stage(task.machine.stageId), let destination = task.pipeline.stage(target) else { throw invalidState("Стадия не найдена.") }
        guard source.id != target, destination.kind != .gate, destination.kind != .terminal else { throw invalidState("Перенос в эту стадию запрещён.") }
        if task.pipeline.isUpstream(target, of: source.id) { return }
        guard source.kind == .queue, source.onSuccess == target, destination.kind == .agent,
              task.card.hasAcceptanceCriteria else { throw invalidState("Перенос вперёд запрещён; для выхода из Backlog нужны критерии приёмки.") }
        // Validate both intake limits and the execution slot without starting an external run.
        guard try canStart(task, at: at, db: db) else { throw StoreError.schedulerBlocked }
        var candidate = task
        candidate.machine.stageId = target; candidate.machine.state = .queued(nil); candidate.card.retryAt = nil
        guard try canStart(candidate, at: at, db: db) else { throw StoreError.schedulerBlocked }
    }

    private static func validTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !raw.contains("\0") else { throw invalidRequest("Укажите заголовок задачи; поля не должны содержать NUL.") }
        return title
    }
    private static func validBody(_ body: String) throws {
        if body.contains("\0") { throw invalidRequest("Описание содержит NUL.") }
    }
    private static func invalidRequest(_ message: String) -> StoreError { .rejected(CommandError(code: "invalid_request", message: message)) }
    private static func invalidState(_ message: String) -> StoreError { .rejected(CommandError(code: CommandError.invalidStateCode, message: message)) }

    private static func saveUpdatedTask(_ task: DurableTask, commandId: CommandID, at: Date, edited: Bool = false, db: Database) throws -> Seq {
        try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try encode(task), task.card.id.rawValue])
        if edited { _ = try journal(.taskEdited(task.card), task: task, commandId: commandId, at: at, db: db) }
        return try journal(.taskUpdated(task.card), task: task, commandId: commandId, at: at, db: db)
    }
    static func saveUpdatedProject(_ project: ProjectRecord, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        try db.execute(sql: "UPDATE project SET payload = ? WHERE id = ?", arguments: [try encode(project), project.summary.id.rawValue])
        return try journal(.projectUpdated(project.summary), projectId: project.summary.id, commandId: commandId, at: at, db: db)
    }
    private static func saveWireSettings(_ settings: GlobalSettings, commandId: CommandID, at: Date, db: Database) throws -> Seq {
        try validateSettings(settings)
        try db.execute(sql: "UPDATE global_settings SET payload = ? WHERE id = 1", arguments: [try encode(settings)])
        return try journal(.settingsChanged(SettingsChange(key: "global", value: "updated", settings: settings)), projectId: nil, commandId: commandId, at: at, db: db)
    }

    static func failure(_ error: StoreError, commandId: CommandID) -> CommandReply {
        let refusal: CommandError
        switch error {
        case .rejected(let error): refusal = error
        case .taskMissing, .projectMissing: refusal = CommandError(code: CommandError.notFoundCode, message: "Задача или проект не найдены.")
        case .commandIdConflict: refusal = CommandError(code: "command_id_conflict", message: "Этот идентификатор уже использован для другого действия.")
        case .incompleteProjection: refusal = CommandError(code: "incomplete_projection", message: "Сохранённые данные ещё не содержат полной проекции.")
        case .settingsInvalid: refusal = CommandError(code: "invalid_request", message: "Некорректные настройки или отсутствует согласие на квоту.")
        case .schedulerBlocked: refusal = CommandError(code: "scheduler_blocked", message: "Запуск сейчас заблокирован паузой или лимитом.")
        case .invalidPipeline: refusal = CommandError(code: "pipeline_invalid", message: "Пайплайн не поддерживается этим backend.")
        case .taskExists: refusal = CommandError(code: "task_exists", message: "Задача с таким идентификатором уже существует.")
        case .questionInvalid: refusal = CommandError(code: CommandError.invalidStateCode, message: "Вопрос уже закрыт или принадлежит другому запуску.")
        default: refusal = CommandError(code: "unsupported_command", message: "Операция не поддерживается этим backend.")
        }
        return CommandReply(commandId: commandId, seq: nil, result: .error(refusal))
    }
}
