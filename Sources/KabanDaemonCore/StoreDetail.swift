import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    static func saveDetail(_ detail: StoredDetail, taskId: TaskID, db: Database) throws {
        try db.execute(sql: "UPDATE task_detail SET payload = ? WHERE task_id = ?", arguments: [try encode(detail), taskId.rawValue])
    }
    static func validateManagedCommand(_ command: DurableTaskCommand, task: DurableTask, at: Date, db: Database) throws {
        guard try isManaged(task.card.id, db: db) else { return }
        let project = try Self.project(task.card.projectId, db: db)
        if project.production != nil {
            switch command {
            case .cancel, .start, .startBlocked, .pause, .resume, .answer, .approve, .requestChanges, .reject, .move, .retryStage, .acceptSuspicious, .humanContextChanged: break
            case .completeStage, .returnToStage, .requestHuman, .gatesPassed, .gatesFailed, .mergeConflict, .mainDirty, .mainCleaned, .mainMoved, .merged, .resultClean, .resultReadOnly, .resultSuspicious, .resultIncident, .daemonRestarted, .runFailed, .modelMismatch, .gitDenialLimit:
                guard let run = task.runSpecId,
                      let data = try Data.fetchOne(db, sql: "SELECT payload FROM run_spec WHERE run_id = ? AND task_id = ?", arguments: [run.rawValue, task.card.id.rawValue]),
                      try decode(RunSpec.self, data).stageId == task.machine.stageId else { throw StoreError.incompleteProjection }
            }
        }
        switch command {
        case .answer(_, let id):
            if let id {
                let d = try detail(task.card.id, db: db)
                guard let current = d.questions.last(where: { $0.answeredAt == nil }), id == current.request.requestId,
                      current.request.runId == task.machine.lastRunId else { throw StoreError.questionInvalid }
            }
        case .start(let runId):
            if let detail = try Self.mcpBlockDetail(task.card.projectId, db: db) {
                throw StoreError.rejected(CommandError(code: "mcp_unexpected", message: detail))
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM run_spec WHERE run_id = ?)", arguments: [runId.rawValue]) != true else { throw StoreError.commandIdConflict }
            if task.pipeline.stage(task.machine.stageId)?.kind == .agent {
                let details = try Data.fetchAll(db, sql: "SELECT payload FROM task_detail").map { try decode(StoredDetail.self, $0) }
                guard !details.flatMap(\.runs).contains(where: { $0.id == runId }) else { throw StoreError.commandIdConflict }
            }
            guard try canStart(task, at: at, db: db) else { throw StoreError.schedulerBlocked }
        default: break
        }
    }
    /// Feed, run summaries, question IDs and answers are facts of the committed command, not delayed worker projections.
    static func persistDetail(before: TaskMachineState, task: DurableTask, command: DurableTaskCommand, effects: [TaskEffect], commandId: CommandID, at: Date, db: Database) throws -> Seq? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM task_detail WHERE task_id = ?", arguments: [task.card.id.rawValue]) else {
            // Legacy v1 rows did not store detail; don't fabricate a history from the retained journal.
            return nil
        }
        if before.stageId != task.machine.stageId || task.machine.state.status == .done || task.machine.state.status == .cancelled {
            try db.execute(sql: "DELETE FROM human_admission WHERE task_id = ?", arguments: [task.card.id.rawValue])
        }
        if case .start = command, task.pipeline.stage(task.machine.stageId)?.kind == .human, task.machine.state == .waitingHuman(.review) {
            try db.execute(sql: "INSERT INTO human_admission(task_id, stage_id) VALUES (?, ?) ON CONFLICT(task_id) DO NOTHING", arguments: [task.card.id.rawValue, task.machine.stageId.rawValue])
        }
        var d = try decode(StoredDetail.self, data)
        var first: Seq?
        func emit(_ event: JournalEvent) throws {
            let seq = try journal(event, task: task, commandId: commandId, at: at, db: db)
            if first == nil { first = seq }
        }
        for (index, effect) in effects.enumerated() {
            let id = "\(commandId.uuidString.lowercased())/\(index)"
            switch effect {
            case .recordTransition(let transition):
                d.feed.append(FeedItem(id: id, at: at, kind: "transition", text: "\(transition.from.status.rawValue) → \(transition.to.status.rawValue)", runId: transition.runId))
            case .startAgentRun(let request):
                d.runs.append(RunSummary(id: request.runId, taskId: task.card.id, stageId: request.stageId, number: d.runs.count + 1, status: .running,
                                         requestedModel: request.model, startedAt: at))
            case .recordHumanRequest(let question, let run):
                let question = SecretText.redact(question)
                let request = HumanRequest(requestId: HumanRequestID(rawValue: id), taskId: task.card.id, runId: run, question: question)
                d.questions.append(StoredQuestion(request: request))
                d.feed.append(FeedItem(id: id, at: at, kind: "question", text: question, runId: run))
                try emit(.humanRequested(request))
            case .recordHumanAnswer(let text, let requestedId):
                let text = SecretText.redact(text)
                let index = d.questions.lastIndex { $0.answeredAt == nil && (requestedId == nil || $0.request.requestId == requestedId) }
                let id = index.map { d.questions[$0].request.requestId } ?? requestedId
                if let index { d.questions[index].answeredAt = at; d.questions[index].answer = text }
                d.feed.append(FeedItem(id: "\(commandId.uuidString.lowercased())/answer", at: at, kind: "answer", text: text, runId: task.machine.lastRunId))
                try emit(.humanAnswered(HumanAnswer(taskId: task.card.id, requestId: id, text: text)))
            default: break
            }
        }
        if let oldRun = before.currentRunId, task.machine.currentRunId != oldRun,
           let index = d.runs.firstIndex(where: { $0.id == oldRun && $0.endedAt == nil }) {
            d.runs[index].endedAt = at
            switch command {
            case .requestHuman: d.runs[index].status = .succeeded; d.runs[index].endReason = .askedHuman
            case .completeStage: d.runs[index].status = .succeeded; d.runs[index].endReason = .completed
            case .returnToStage: d.runs[index].status = .succeeded; d.runs[index].endReason = .returned
            case .daemonRestarted: d.runs[index].status = .killed; d.runs[index].endReason = .daemonRestart; d.runs[index].countsTowardLimits = false
            case .pause:
                d.runs[index].status = .killed; d.runs[index].endReason = .pausedByHuman; d.runs[index].countsTowardLimits = false
            case .move, .cancel, .reject:
                d.runs[index].status = .killed; d.runs[index].endReason = .movedByHuman; d.runs[index].countsTowardLimits = false
            case .runFailed(_, let failure):
                d.runs[index].status = failure.charges ? .failed : .killed
                d.runs[index].endReason = runEndReason(failure)
                d.runs[index].countsTowardLimits = failure.charges
            case .modelMismatch:
                d.runs[index].status = .killed; d.runs[index].endReason = .modelSubstituted; d.runs[index].countsTowardLimits = false
            case .gitDenialLimit:
                d.runs[index].status = .killed; d.runs[index].countsTowardLimits = false
            default: d.runs[index].status = .killed
            }
        }
        if case .completeStage(let run, let summary) = command {
            let summary = SecretText.redact(summary)
            let id = commandId.uuidString.lowercased()
            d.artifacts.append(TaskArtifact(id: ArtifactID(rawValue: id), taskId: task.card.id, runId: run, stageId: before.stageId, kind: "summary", text: summary, createdAt: at))
            d.feed.append(FeedItem(id: id, at: at, kind: "summary", text: summary, runId: run))
        }
        if case .requestChanges(let comments, _) = command {
            // This is a review note, not an answer to an outstanding question.
            // Persist with the state mutation so retention/restart cannot lose it.
            d.feed.append(FeedItem(id: commandId.uuidString.lowercased() + "/review", at: at,
                                  kind: "review_comment", text: SecretText.redact(comments), runId: before.lastRunId))
        }
        if case .returnToStage(let run, _, let issues) = command {
            for (offset, issue) in issues.enumerated() {
                let issue = SecretText.redact(issue)
                let id = "\(commandId.uuidString.lowercased())/issue/\(offset)"
                d.artifacts.append(TaskArtifact(id: ArtifactID(rawValue: id), taskId: task.card.id, runId: run, stageId: before.stageId, kind: "issue", text: issue, createdAt: at))
                d.feed.append(FeedItem(id: id, at: at, kind: "issue", text: issue, runId: run))
            }
        }
        try saveDetail(d, taskId: task.card.id, db: db)
        if task.machine.state.status == .queued && (before.state.status != .queued || before.stageId != task.machine.stageId) {
            try db.execute(sql: "UPDATE task_admission SET queue_seq = ? WHERE task_id = ?", arguments: [try seq(db), task.card.id.rawValue])
        }
        return first
    }

    static func runEndReason(_ failure: RunFailure) -> RunEndReason? {
        switch failure {
        case .crash: .crash
        case .stallTimeout: .stallTimeout
        case .wallTimeout: .wallTimeout
        case .noFinalCall: .noFinalCall
        case .rateLimit: .rateLimit
        case .runnerAuth: .runnerAuth
        case .silentExit: .silentExit
        case .usageExhausted, .modelUnavailable: nil
        }
    }
}
