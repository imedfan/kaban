import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    public func pendingEffectItems() throws -> [PendingEffect] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM effect WHERE status = 'pending' ORDER BY rowid").map { try Self.decode(PendingEffect.self, $0) }
        }
    }

    /// Commits a simulated result, transition, audit and acknowledgement together.
    /// No process, filesystem, git or network operation is performed.
    public func deliverFake(effectId: String, result: FakeEffectResult, at: Date) throws -> EffectReceipt {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload, status, result, receipt FROM effect WHERE id = ?", arguments: [effectId]) else { throw StoreError.effectMissing }
            let bytes = try Self.encode(result)
            if let stored: Data = row["result"] {
                guard stored == bytes else { throw StoreError.effectResultConflict }
                return try Self.decode(EffectReceipt.self, row["receipt"])
            }
            guard (row["status"] as String) == "pending" else { throw StoreError.effectSuperseded }
            let pending = try Self.decode(PendingEffect.self, row["payload"])
            guard pending.version == 1 else { throw StoreError.unsupportedEffect }
            let command: DurableTaskCommand?
            switch (pending.effect, result) {
            case (.startAgentRun(let run), .question(let question)): command = .requestHuman(run.runId, question: question)
            case (.startAgentRun(let run), .completed(let summary)): command = .completeStage(run.runId, summary: summary)
            case (.runResultCheck, .clean): command = .resultClean
            case (.runGates, .gatesPassed): command = .gatesPassed
            case (.killRun, .acknowledged), (.saveWipAndRollback, .acknowledged), (.commitStage, .acknowledged),
                 (.scheduleRetry, .acknowledged), (.expireGitGrants, .acknowledged), (.cleanupClone, .acknowledged), (.notifyHuman, .acknowledged): command = nil
            default: throw StoreError.unsupportedEffect
            }
            // This command identity is created once, inside the result transaction, and is never replayed outside it.
            let id = UUID()
            if let command {
                let request = try Self.encode(Request(kind: "transition", taskId: pending.taskId, body: Self.encode(command)))
                _ = try Self.apply(command, taskId: pending.taskId, commandId: id, at: at, request: request, db: db)
            }
            let task = try Self.task(pending.taskId, db: db)
            var detail = try Self.detail(pending.taskId, db: db)
            detail.feed.append(FeedItem(id: effectId + "/simulated", at: at, kind: "simulated", text: "Fake effect result: \(String(describing: pending.effect))", runId: task.machine.lastRunId))
            try Self.saveDetail(detail, taskId: pending.taskId, db: db)
            let seq = try Self.journal(.taskUpdated(task.card), task: task, commandId: id, at: at, db: db)
            let receipt = EffectReceipt(effectId: effectId, seq: seq, task: task)
            try db.execute(sql: "UPDATE effect SET status = 'acknowledged', result = ?, receipt = ? WHERE id = ?", arguments: [bytes, try Self.encode(receipt), effectId])
            let left = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM effect WHERE command_id = ? AND status = 'pending'", arguments: [pending.commandId.uuidString.lowercased()])!
            if left == 0 { try db.execute(sql: "DELETE FROM effect_outbox WHERE id = ?", arguments: [pending.commandId.uuidString]) }
            return receipt
        }
    }
}
