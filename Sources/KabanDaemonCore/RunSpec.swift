import Foundation
import GRDB
import KabanKit
import KabanProtocol

/// Immutable input to an invocation. Execution workers must load this row, rather than consult
/// current project settings or mutable working files. nil source denotes a simulation/legacy task.
public struct RunSpec: Codable, Hashable, Sendable {
    public let runId: RunID
    public let taskId: TaskID
    public let stageId: StageID
    public let pipelineVersion: String
    public let pipeline: PipelineConfig
    public let source: PipelineSource?
    public let gitPolicy: EffectiveGitPolicy?
    public let identity: GitIdentity?
    public let returnReason: ReturnReason?
}

extension KabanStore {
    public func getRunSpec(_ runId: RunID) throws -> RunSpec? {
        try database.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM run_spec WHERE run_id = ?", arguments: [runId.rawValue]).map { try Self.decode(RunSpec.self, $0) } }
    }
    static func bindPipelineForStart(_ task: inout DurableTask, db: Database) throws {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ? AND id NOT IN (SELECT project_id FROM removed_project)", arguments: [task.card.projectId.rawValue]) else { return }
        let record = try decode(ProjectRecord.self, data)
        guard record.production != nil else { return }
        guard record.summary.availability == .available, record.production?.unavailableReason == nil,
              record.projectedPipeline.isValid, let version = record.projectedPipeline.versionHash,
              record.pipeline.stage(task.machine.stageId) != nil else { throw StoreError.invalidPipeline }
        task.pipeline = record.pipeline; task.pipelineVersion = version
    }
    static func freezeRunSpec(_ runId: RunID, task: DurableTask, db: Database) throws {
        guard let stage = task.pipeline.stage(task.machine.stageId) else { throw StoreError.invalidPipeline }
        let record = try Data.fetchOne(db, sql: "SELECT payload FROM project WHERE id = ?", arguments: [task.card.projectId.rawValue]).map { try decode(ProjectRecord.self, $0) }
        let source: PipelineSource?
        if record?.production != nil {
            guard let hash = task.pipelineVersion,
                  let data = try Data.fetchOne(db, sql: "SELECT payload FROM pipeline_version WHERE project_id = ? AND hash = ?", arguments: [task.card.projectId.rawValue, hash]) else { throw StoreError.incompleteProjection }
            let version = try decode(PipelineVersion.self, data)
            guard version.pipeline == task.pipeline else { throw StoreError.incompleteProjection }
            let latest = record?.production?.source
            source = try latest?.versionHash() == hash ? latest : version.source
        } else { source = nil }
        let hash = try task.pipelineVersion ?? PipelineContentHash.sha256(String(decoding: encode(task.pipeline), as: UTF8.self))
        let spec = RunSpec(runId: runId, taskId: task.card.id, stageId: stage.id, pipelineVersion: hash,
                           pipeline: task.pipeline, source: source,
                           gitPolicy: stage.kind == .agent ? GitPolicyResolver.resolve(project: task.pipeline.git, stage: stage) : nil,
                           identity: record?.summary.identity, returnReason: task.machine.returnReason)
        try db.execute(sql: "INSERT INTO run_spec(run_id, task_id, payload) VALUES (?, ?, ?)", arguments: [runId.rawValue, task.card.id.rawValue, try encode(spec)])
    }
}
