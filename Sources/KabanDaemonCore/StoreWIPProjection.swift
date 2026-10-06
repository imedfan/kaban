import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    /// Same read transaction as TaskDetail and its seq. No effect is executed by
    /// this query; retention of journal rows doesn't erase effect receipts.
    static func wipRestoreOperations(_ taskId: TaskID, db: Database) throws -> [WIPRestoreOperation] {
        let rows = try Row.fetchAll(db, sql: "SELECT payload, status, result, receipt FROM effect WHERE status IN ('pending', 'claimed', 'acknowledged', 'superseded') AND task_id = ? ORDER BY rowid", arguments: [taskId.rawValue])
        return try rows.compactMap { row in
            let pending = try decode(PendingEffect.self, row["payload"])
            guard case .restoreWIP(let run, let ref, _, _) = pending.effect else { return nil }
            let state: String = row["status"]
            if state == "pending" || state == "claimed" {
                return .init(commandId: pending.commandId, runId: run, wipRef: ref, status: .pending)
            }
            if state == "superseded" {
                return .init(commandId: pending.commandId, runId: run, wipRef: ref, status: .superseded)
            }
            guard let result: Data = row["result"], let receiptData: Data = row["receipt"] else { throw StoreError.incompleteProjection }
            let outcome = try decode(RealEffectOutcome.self, result)
            let receipt = try decode(EffectReceipt.self, receiptData)
            guard receipt.effectId == pending.id, receipt.task.card.id == taskId else { throw StoreError.incompleteProjection }
            switch outcome {
            case .acknowledged:
                return .init(commandId: pending.commandId, runId: run, wipRef: ref, status: .succeeded, completedSeq: receipt.seq)
            case .restoreFailed(let message):
                return .init(commandId: pending.commandId, runId: run, wipRef: ref, status: .failed, completedSeq: receipt.seq, message: SecretText.redact(message))
            default: throw StoreError.incompleteProjection
            }
        }
    }
}
