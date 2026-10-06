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
            let pending = try Self.decode(PendingEffect.self, row["payload"])
            let owner = try Self.task(pending.taskId, db: db)
            let production = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ?", arguments: [owner.card.projectId.rawValue]).map { try Self.decode(ProjectRecord.self, $0).production != nil } ?? false
            guard !production else { throw StoreError.unsupportedEffect }
            let bytes = try Self.encode(result)
            if let stored: Data = row["result"] {
                guard stored == bytes else { throw StoreError.effectResultConflict }
                return try Self.decode(EffectReceipt.self, row["receipt"])
            }
            guard (row["status"] as String) == "pending" else { throw StoreError.effectSuperseded }
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
            let left = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM effect WHERE command_id = ? AND status IN ('pending', 'claimed')", arguments: [pending.commandId.uuidString.lowercased()])!
            if left == 0 { try db.execute(sql: "DELETE FROM effect_outbox WHERE id = ?", arguments: [pending.commandId.uuidString]) }
            return receipt
        }
    }

    static func migrateEffectExecution(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE effect ADD COLUMN fencing INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE effect ADD COLUMN lease_id TEXT")
        try db.execute(sql: "ALTER TABLE effect ADD COLUMN lease_owner TEXT")
        try db.execute(sql: "ALTER TABLE effect ADD COLUMN lease_until REAL")
        try db.execute(sql: "ALTER TABLE effect ADD COLUMN external_fact BLOB")
        try db.execute(sql: "ALTER TABLE effect ADD COLUMN diagnostic TEXT")
    }

    /// Claims one effect. The returned lease is visible to other connections; no process or git work runs here.
    public func claimEffect(id: String? = nil, owner: String, leaseFor: TimeInterval = 30, at: Date) throws -> EffectLease? {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in try Self.claim(id: id, owner: owner, leaseFor: leaseFor, at: at, db: db) }
    }

    /// Records a fact that was observed after the claim commit. The original effect payload is not rewritten.
    public func recordExternalFact(effectId: String, leaseId: String, fact: ExternalEffectFact) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        try database.write { db in
            _ = try Self.storeFact(effectId: effectId, leaseId: leaseId, fact: fact, db: db)
        }
    }

    /// Keeps an unfinished effect's original payload and records why it has no receipt yet.
    public func recordEffectDiagnostic(effectId: String, leaseId: String, diagnostic: String) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT status, lease_id FROM effect WHERE id = ?", arguments: [effectId]) else { throw StoreError.effectMissing }
            if (row["status"] as String) == "superseded" { throw StoreError.effectSuperseded }
            guard (row["status"] as String) == "claimed", (row["lease_id"] as String?) == leaseId else { throw StoreError.effectLeaseStale }
            try db.execute(sql: "UPDATE effect SET diagnostic = ? WHERE id = ? AND lease_id = ?", arguments: [diagnostic, effectId, leaseId])
        }
    }

    /// Applies a live result in one transaction. Call this only after the external action, from outside the claim transaction.
    @discardableResult
    public func commitEffectResult(effectId: String, leaseId: String, fact: ExternalEffectFact, at: Date, diagnostic: String? = nil) throws -> EffectReceipt {
        projectOperations.lock(); defer { projectOperations.unlock() }
        return try database.write { db in
            try Self.commit(effectId: effectId, leaseId: leaseId, fact: fact, at: at, diagnostic: diagnostic, db: db)
        }
    }

    /// Reconciles leases left by a dead owner. A fact is receipted once; a missing fact may be reclaimed and is not exactly-once.
    public func recoverEffectExecution(at: Date, reclaimUnexpired: Bool) throws -> [EffectReceipt] {
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, external_fact FROM effect WHERE status = 'claimed' ORDER BY rowid")
        }
        var receipts: [EffectReceipt] = []
        for row in rows {
            let id: String = row["id"]
            if let factData: Data = row["external_fact"] {
                let fact = try Self.decode(ExternalEffectFact.self, factData)
                if fact.phase == .finished, fact.outcome != nil {
                    let leaseId = try database.read { db in try String.fetchOne(db, sql: "SELECT lease_id FROM effect WHERE id = ?", arguments: [id]) }
                    if let leaseId {
                        receipts.append(try commitEffectResult(effectId: id, leaseId: leaseId, fact: fact, at: at))
                    }
                } else {
                    try database.write { db in
                        try db.execute(sql: "UPDATE effect SET diagnostic = ? WHERE id = ? AND status = 'claimed' AND diagnostic IS NULL", arguments: [EffectExecutionDiagnostic.observedUnfinished, id])
                    }
                }
            } else if try reclaimUnexpired || leaseExpired(id, at: at) {
                try database.write { db in
                    try db.execute(sql: "UPDATE effect SET status = 'pending', lease_id = NULL, lease_owner = NULL, lease_until = NULL, diagnostic = ? WHERE id = ? AND status = 'claimed' AND external_fact IS NULL", arguments: [EffectExecutionDiagnostic.reclaim, id])
                }
            }
        }
        return receipts
    }

    /// Opt-in pass for lifecycle acknowledgements. Agent, gate, and merge effects stay pending for their own drivers.
    /// The side-effect file is appended only after `claimEffect` has committed and before the receipt transaction.
    public func runEffectPass(owner: String, at: Date, sideEffectLog: String) throws -> [String] {
        var lines = try storedPassLines()
        let ids = try protocolAckIds()
        for id in ids {
            guard let lease = try claimEffect(id: id, owner: owner, leaseFor: 30, at: at) else { continue }
            let actionId = lease.effectId + "/fact"
            try Self.appendSideEffect(log: sideEffectLog, effectId: lease.effectId, fencing: lease.fencing, actionId: actionId)
            let fact = ExternalEffectFact(actionId: actionId, phase: .finished, outcome: .acknowledged)
            let receipt = try commitEffectResult(effectId: lease.effectId, leaseId: lease.leaseId, fact: fact, at: at, diagnostic: EffectExecutionDiagnostic.protocolReceipt)
            lines.append(contentsOf: Self.passLines(effectId: lease.effectId, fencing: lease.fencing, actionId: actionId, seq: receipt.seq))
        }
        return lines
    }

    private func leaseExpired(_ id: String, at: Date) throws -> Bool {
        try database.read { db in
            guard let until = try Double.fetchOne(db, sql: "SELECT lease_until FROM effect WHERE id = ?", arguments: [id]) else { return true }
            return until <= at.timeIntervalSince1970
        }
    }

    private func protocolAckIds() throws -> [String] {
        try database.read { db in
            var ids: [String] = []
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM effect WHERE status = 'pending' AND external_fact IS NULL ORDER BY rowid") {
                let pending = try Self.decode(PendingEffect.self, row["payload"])
                if Self.acceptsProtocolAcknowledgement(pending.effect) { ids.append(row["id"]) }
            }
            return ids
        }
    }

    private func storedPassLines() throws -> [String] {
        try database.read { db -> [String] in
            var lines: [String] = []
            let rows = try Row.fetchAll(db, sql: "SELECT id, fencing, external_fact, receipt FROM effect WHERE status = 'acknowledged' AND external_fact IS NOT NULL ORDER BY rowid")
            for row in rows {
                guard let factData: Data = row["external_fact"], let receiptData: Data = row["receipt"] else { continue }
                let fact = try Self.decode(ExternalEffectFact.self, factData)
                let receipt = try Self.decode(EffectReceipt.self, receiptData)
                lines.append(contentsOf: Self.passLines(effectId: row["id"], fencing: row["fencing"], actionId: fact.actionId, seq: receipt.seq))
            }
            return lines
        }
    }

    static func passLines(effectId: String, fencing: Int, actionId: String, seq: Seq) -> [String] {
        [
            "effect claim \(effectId) fencing \(fencing)",
            "effect side-effect \(effectId) after-commit \(actionId)",
            "effect receipt \(effectId) seq \(seq)",
        ]
    }

    static func appendSideEffect(log: String, effectId: String, fencing: Int, actionId: String) throws {
        let url = URL(fileURLWithPath: log)
        if !FileManager.default.fileExists(atPath: log) {
            guard FileManager.default.createFile(atPath: log, contents: nil) else { throw POSIXError(.EIO) }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(effectId) \(fencing) \(actionId)\n".utf8))
    }

    static func claim(id: String?, owner: String, leaseFor: TimeInterval, at: Date, db: Database) throws -> EffectLease? {
        let now = at.timeIntervalSince1970
        var skipped: [String] = []
        while skipped.count < 64 {
            var sql = "SELECT id FROM effect WHERE external_fact IS NULL AND (status = 'pending' OR (status = 'claimed' AND lease_until <= ?))"
            var arguments: [DatabaseValueConvertible] = [now]
            if !skipped.isEmpty {
                sql += " AND id NOT IN (\(skipped.map { _ in "?" }.joined(separator: ",")))"
                arguments.append(contentsOf: skipped)
            }
            if let id {
                sql += " AND id = ?"
                arguments.append(id)
            }
            sql += " ORDER BY rowid LIMIT 1"
            guard let candidate = try String.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) else { return nil }
            let leaseId = UUID().uuidString.lowercased()
            let until = at.addingTimeInterval(leaseFor).timeIntervalSince1970
            try db.execute(sql: """
                UPDATE effect
                SET status = 'claimed', lease_id = ?, lease_owner = ?, fencing = fencing + 1, lease_until = ?, diagnostic = NULL
                WHERE id = ? AND external_fact IS NULL AND (status = 'pending' OR (status = 'claimed' AND lease_until <= ?))
                """, arguments: [leaseId, owner, until, candidate, now])
            if db.changesCount == 1 {
                guard let row = try Row.fetchOne(db, sql: "SELECT fencing, payload FROM effect WHERE id = ?", arguments: [candidate]) else { throw StoreError.effectMissing }
                return EffectLease(effectId: candidate, leaseId: leaseId, owner: owner, fencing: row["fencing"], expiresAt: Date(timeIntervalSince1970: until), payload: try decode(PendingEffect.self, row["payload"]))
            }
            skipped.append(candidate)
            if id != nil { return nil }
        }
        return nil
    }

    static func storeFact(effectId: String, leaseId: String, fact: ExternalEffectFact, db: Database) throws -> Data {
        guard let row = try Row.fetchOne(db, sql: "SELECT status, lease_id, external_fact, result FROM effect WHERE id = ?", arguments: [effectId]) else { throw StoreError.effectMissing }
        let encoded = try encode(fact)
        let status: String = row["status"]
        if status == "acknowledged" {
            if let existing: Data = row["external_fact"], existing != encoded { throw StoreError.effectResultConflict }
            return encoded
        }
        if status == "superseded" { throw StoreError.effectSuperseded }
        guard status == "claimed", (row["lease_id"] as String?) == leaseId else { throw StoreError.effectLeaseStale }
        if let existing: Data = row["external_fact"] {
            if existing == encoded { return encoded }
            let previous = try decode(ExternalEffectFact.self, existing)
            let upgrade = previous.phase == .started && previous.outcome == nil && fact.phase == .finished && fact.outcome != nil && previous.actionId == fact.actionId
            guard upgrade else { throw StoreError.effectResultConflict }
        }
        try db.execute(sql: "UPDATE effect SET external_fact = ? WHERE id = ? AND lease_id = ?", arguments: [encoded, effectId, leaseId])
        return encoded
    }

    static func commit(effectId: String, leaseId: String, fact: ExternalEffectFact, at: Date, diagnostic: String?, db: Database) throws -> EffectReceipt {
        guard fact.phase == .finished, let outcome = fact.outcome else { throw StoreError.unsupportedEffect }
        guard let row = try Row.fetchOne(db, sql: "SELECT payload, status, lease_id, result, receipt, external_fact FROM effect WHERE id = ?", arguments: [effectId]) else { throw StoreError.effectMissing }
        let resultBytes = try encode(outcome)
        if let stored: Data = row["result"] {
            guard stored == resultBytes else { throw StoreError.effectResultConflict }
            if let existing: Data = row["external_fact"] {
                let previous = try decode(ExternalEffectFact.self, existing)
                guard previous.actionId == fact.actionId, previous.outcome == fact.outcome else { throw StoreError.effectResultConflict }
            }
            return try decode(EffectReceipt.self, row["receipt"])
        }
        let status: String = row["status"]
        if status == "superseded" { throw StoreError.effectSuperseded }
        guard status == "claimed", (row["lease_id"] as String?) == leaseId else { throw StoreError.effectLeaseStale }
        _ = try storeFact(effectId: effectId, leaseId: leaseId, fact: fact, db: db)
        let pending = try decode(PendingEffect.self, row["payload"])
        guard pending.version == 1 else { throw StoreError.unsupportedEffect }
        var task = try Self.task(pending.taskId, db: db)
        guard effectIsCurrent(pending.effect, task: task) else { throw StoreError.effectSuperseded }
        let command = try command(for: pending.effect, outcome: outcome)
        let transitionId = UUID()
        if let command {
            let request = try encode(Request(kind: "effect", taskId: pending.taskId, body: encode(command)))
            _ = try Self.apply(command, taskId: pending.taskId, commandId: transitionId, at: at, request: request, db: db)
            task = try Self.task(pending.taskId, db: db)
        }
        var detail = try detail(pending.taskId, db: db)
        detail.feed.append(FeedItem(id: effectId + "/execution", at: at, kind: "execution", text: "Effect execution receipt", runId: task.machine.lastRunId))
        try saveDetail(detail, taskId: pending.taskId, db: db)
        let seq = try journal(.taskUpdated(task.card), task: task, commandId: transitionId, at: at, db: db)
        task = try Self.task(pending.taskId, db: db)
        let receipt = EffectReceipt(effectId: effectId, seq: seq, task: task)
        try db.execute(sql: "UPDATE effect SET status = 'acknowledged', result = ?, receipt = ?, diagnostic = ? WHERE id = ? AND lease_id = ?", arguments: [resultBytes, try encode(receipt), diagnostic, effectId, leaseId])
        guard db.changesCount == 1 else { throw StoreError.effectLeaseStale }
        let left = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM effect WHERE command_id = ? AND status IN ('pending', 'claimed')", arguments: [pending.commandId.uuidString.lowercased()])!
        if left == 0 { try db.execute(sql: "DELETE FROM effect_outbox WHERE id = ?", arguments: [pending.commandId.uuidString]) }
        return receipt
    }

    static func effectIsCurrent(_ effect: TaskEffect, task: DurableTask) -> Bool {
        switch effect {
        case .startAgentRun(let request):
            return task.machine.state.status == .running && task.machine.currentRunId == request.runId
        case .runGates(let stage, _), .runResultCheck(let stage), .startMerge(let stage, _):
            return task.machine.state.status == .gating && task.machine.stageId == stage
        case .fastForwardMerge:
            return task.machine.state.status == .gating && task.machine.gatingPhase == .fastForward
        case .killRun, .saveWipAndRollback, .commitStage, .scheduleRetry, .expireGitGrants, .cleanupClone, .notifyHuman,
             .raiseRateLimit, .raiseRunnerUnavailable, .raiseUsageExhausted, .raiseModelFlag, .requestModelProbe,
             .openIncident, .resolveIncident, .reportSuspiciousFiles, .acceptSuspiciousFiles:
            return true
        case .recordTransition, .recordHumanRequest, .recordHumanAnswer:
            return false
        }
    }

    static func command(for effect: TaskEffect, outcome: RealEffectOutcome) throws -> DurableTaskCommand? {
        switch (effect, outcome) {
        case (.startAgentRun(let run), .question(let question)): return .requestHuman(run.runId, question: question)
        case (.startAgentRun(let run), .completed(let summary)): return .completeStage(run.runId, summary: summary)
        case (.runResultCheck, .clean): return .resultClean
        case (.runResultCheck, .readOnlyChanges): return .resultReadOnly
        case (.runResultCheck, .suspiciousFiles(let files)): return .resultSuspicious(files)
        case (.runResultCheck, .incident(let kind, let rolled)): return .resultIncident(kind, rolledBack: rolled)
        case (.runGates, .gatesPassed): return .gatesPassed
        case (.runGates, .gatesFailed(let output)): return .gatesFailed(output: output)
        case (.startMerge, .mergeConflict(let files)): return .mergeConflict(files)
        case (.startMerge, .gatesPassed): return .gatesPassed
        case (.startMerge, .gatesFailed(let output)): return .gatesFailed(output: output)
        case (.fastForwardMerge, .mainDirty): return .mainDirty
        case (.fastForwardMerge, .mainMoved): return .mainMoved
        case (.fastForwardMerge, .merged): return .merged
        case (.fastForwardMerge, .suspiciousFiles(let files)): return .resultSuspicious(files)
        case (.fastForwardMerge, .incident(let kind, let rolled)): return .resultIncident(kind, rolledBack: rolled)
        case (.fastForwardMerge, .readOnlyChanges): return .resultReadOnly
        case (.killRun, .acknowledged), (.saveWipAndRollback, .acknowledged), (.commitStage, .acknowledged),
             (.scheduleRetry, .acknowledged), (.expireGitGrants, .acknowledged), (.cleanupClone, .acknowledged), (.notifyHuman, .acknowledged):
            return nil
        default: throw StoreError.unsupportedEffect
        }
    }

    static func acceptsProtocolAcknowledgement(_ effect: TaskEffect) -> Bool {
        switch effect {
        case .killRun, .saveWipAndRollback, .commitStage, .scheduleRetry, .expireGitGrants, .cleanupClone, .notifyHuman:
            return true
        default:
            return false
        }
    }
}
