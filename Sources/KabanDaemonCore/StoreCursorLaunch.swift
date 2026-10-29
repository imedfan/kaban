import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    func launchGrants(taskId: TaskID, stageId: StageID) throws -> [GitGrantSnapshot] {
        try database.read { db in
            try Self.detail(taskId, db: db).gitGrants.filter {
                $0.taskId == taskId && $0.stageId == stageId && $0.consumption == nil && $0.revocation == nil && $0.expiry == nil
            }
        }
    }

    /// Record the launch handoff before opening the exec gate. A crash before gate release
    /// may prevent delivery; this is not an exactly-once receipt from the external process.
    func saveStartedProcess(_ record: AgentProcessRecord, grants: [GitGrantSnapshot], at: Date) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO agent_process(run_id, payload) VALUES (?, ?)", arguments: [record.runId, try Self.encode(record)])
            guard !grants.isEmpty else { return }
            let taskId = TaskID(rawValue: record.taskId)
            let task = try Self.task(taskId, db: db)
            var detail = try Self.detail(taskId, db: db)
            for grant in grants {
                guard let index = detail.gitGrants.firstIndex(where: { $0.grant.grantId == grant.grant.grantId }) else { continue }
                let delivery = GitGrantDelivered(grantId: grant.grant.grantId, runId: RunID(rawValue: record.runId), via: .nextPrompt)
                if detail.gitGrants[index].delivery == delivery { continue }
                detail.gitGrants[index].delivery = delivery
                detail.gitGrants[index].deliveredAt = at
                _ = try Self.journal(.gitGrantDelivered(delivery), task: task, commandId: UUID(), at: at, db: db)
            }
            try Self.saveDetail(detail, taskId: taskId, db: db)
        }
    }
}
