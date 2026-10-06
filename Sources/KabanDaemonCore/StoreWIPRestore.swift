import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func canRestoreWIP(_ task: DurableTask) -> Bool {
        task.pipeline.stage(task.machine.stageId)?.kind == .agent &&
        [.queued, .retryWait, .paused, .waitingHuman].contains(task.machine.state.status)
    }

    /// Accept only an exact ref from this task's durable run history. No correlated
    /// completion event is emitted until the git action and its receipt finish.
    func executeWIPRestore(_ envelope: CommandEnvelope, at: Date) throws -> CommandReply {
        let request = try Self.encode(envelope)
        do {
            if let reply = try database.read({ try Self.wireReplay(envelope.commandId, request: request, db: $0) }) { return reply }
        } catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
        guard envelope.protocolVersion == KabanCoding.protocolVersion else {
            return .init(commandId: envelope.commandId, seq: nil, result: .error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        guard case .restoreWIP(let taskId, let runId, let ref) = envelope.command else { throw StoreError.unsupportedEffect }
        let effect: TaskEffect
        do {
            let context = try database.read { db -> (DurableTask, TaskCloneRecord, GitIdentity?) in
                let task = try Self.task(taskId, db: db)
                let detail = try Self.detail(taskId, db: db)
                guard try Self.isManaged(taskId, db: db), Self.canRestoreWIP(task),
                      detail.runs.contains(where: { $0.id == runId && $0.wipRef == ref }),
                      ref == (try TaskClone.wipRef(runId)),
                      let clone = try Self.cloneRecord(taskId, db: db), clone.phase == "ready" else {
                    throw StoreError.rejected(.init(code: CommandError.invalidStateCode, message: "WIP недоступен в текущем состоянии задачи. Обновите детали."))
                }
                guard try !Self.hasPendingRestore(taskId, db: db) else { throw StoreError.rejected(.init(code: CommandError.invalidStateCode, message: "Восстановление уже выполняется.")) }
                let project = try Self.project(task.card.projectId, db: db)
                return (task, clone, project.summary.identity)
            }
            try TaskClone.authorizeDeletion(candidate: context.1.clonePath, recorded: context.1.clonePath, workspaceRoot: context.1.workspaceRoot, origin: context.1.projectPath)
            let sha = try TaskClone.wipCommit(clone: context.1.clonePath, ref: ref, identity: context.2)
            effect = .restoreWIP(runId: runId, ref: ref, sha: sha, stageId: context.0.machine.stageId)
        } catch {
            let refusal = (error as? StoreError) ?? .rejected(.init(code: "wip_unavailable", message: "Сохранённый WIP не найден или изменён."))
            let reply = Self.failure(refusal, commandId: envelope.commandId)
            try database.write { db in
                try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            }
            return reply
        }
        return try database.write { db in
            let task = try Self.task(taskId, db: db)
            let seq = try Self.seq(db)
            let receipt = DurableReceipt(commandId: envelope.commandId, firstSeq: nil, lastSeq: seq, task: task)
            try Self.saveReceipt(receipt, request: request, db: db)
            let batch = PendingEffectBatch(version: 1, commandId: envelope.commandId, taskId: taskId, effects: [effect], runSpecId: task.runSpecId)
            try Self.enqueue(batch, db: db)
            try db.execute(sql: "INSERT INTO effect_outbox(id, task_id, payload) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, taskId.rawValue, try Self.encode(batch)])
            let reply = CommandReply(commandId: envelope.commandId, seq: seq, result: .ok)
            try db.execute(sql: "INSERT INTO wire_command(id, request, reply) VALUES (?, ?, ?)", arguments: [envelope.commandId.uuidString, request, try Self.encode(reply)])
            return reply
        }
    }

    static func hasPendingRestore(_ taskId: TaskID, db: Database) throws -> Bool {
        for data in try Data.fetchAll(db, sql: "SELECT payload FROM effect WHERE task_id = ? AND status IN ('pending', 'claimed')", arguments: [taskId.rawValue]) {
            if case .restoreWIP = try decode(PendingEffect.self, data).effect { return true }
        }
        return false
    }

    @discardableResult
    public func runWIPRestorePass(owner: String, at: Date) throws -> [EffectReceipt] {
        projectOperations.lock(); defer { projectOperations.unlock() }
        var receipts: [EffectReceipt] = []
        for item in try pendingEffectItems() {
            guard case .restoreWIP(_, let ref, let sha, _) = item.effect else { continue }
            let task = try database.read { try Self.task(item.taskId, db: $0) }
            guard Self.effectIsCurrent(item.effect, task: task) else { continue }
            guard try !allProcessRecords().contains(where: { record in
                record.taskId == item.taskId.rawValue && ProcessGroup.isExecuting(record.pid,
                    birth: .init(seconds: record.birthSeconds, microseconds: record.birthMicroseconds))
            }) else { continue }
            guard let lease = try claimEffect(id: item.id, owner: owner, at: at) else { continue }
            let outcome: RealEffectOutcome
            do {
                guard let clone = try readyClone(item.taskId) else { throw POSIXError(.ENOENT) }
                try TaskClone.restoreWIP(clone: clone.clonePath, ref: ref, sha: sha, commandId: item.commandId,
                    recorded: clone.clonePath, workspaceRoot: clone.workspaceRoot, origin: clone.projectPath, identity: projectIdentity(task))
                outcome = .acknowledged
            } catch { outcome = .restoreFailed("WIP restore failed: \(error)") }
            // A DB failure leaves the lease for recovery. It must never be converted to a failed git action.
            let fact = ExternalEffectFact(actionId: item.id + "/restore", phase: .finished, outcome: outcome)
            receipts.append(try commitEffectResult(effectId: item.id, leaseId: lease.leaseId, fact: fact, at: at))
        }
        return receipts
    }
}
