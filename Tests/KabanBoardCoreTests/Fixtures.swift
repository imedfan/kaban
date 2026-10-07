import Foundation
@testable import KabanBoardCore
import KabanProtocol

enum Fix {
    static let t0 = Date(timeIntervalSince1970: 1_791_100_800) // 2026-10-04T08:00:00Z
    static let project: ProjectID = "p-kaban"
    static let other: ProjectID = "p-site"
    static let command = UUID(uuidString: "00000000-0000-4000-8000-000000000014")!

    static func stage(_ id: String, _ kind: StageKind, order: Int, gates: [String] = [], onSuccess: StageID? = nil) -> StageSummary {
        StageSummary(id: StageID(rawValue: id), name: id, kind: kind, display: StageDisplay(order: order), onSuccess: onSuccess, gates: gates)
    }

    static let baseStages: [StageSummary] = [
        stage("backlog", .queue, order: 0, onSuccess: "dev"),
        stage("dev", .agent, order: 1),
        stage("gate", .gate, order: 2),
        stage("test", .agent, order: 3),
        stage("done", .terminal, order: 4),
    ]

    static func pipeline(_ stages: [StageSummary] = baseStages, project: ProjectID = project) -> PipelineSummary {
        PipelineSummary(projectId: project, versionHash: "v1", stages: stages)
    }

    static func project(
        _ id: ProjectID = project,
        name: String = "kaban",
        openIncidentCount: Int = 0,
        identity: GitIdentity? = nil
    ) -> ProjectSummary {
        ProjectSummary(
            id: id, name: name, path: "/\(id.rawValue)", mascotSeed: id.rawValue,
            openIncidentCount: openIncidentCount, identity: identity
        )
    }

    static func card(
        _ id: String,
        stage: String = "dev",
        state: TaskState = .queued(nil),
        title: String = "Старая",
        project: ProjectID = project,
        files: [SuspiciousFile] = [],
        hasAcceptanceCriteria: Bool = false
    ) -> TaskCard {
        TaskCard(
            id: TaskID(rawValue: id),
            projectId: project,
            title: title,
            stageId: StageID(rawValue: stage),
            state: state,
            suspiciousFiles: files,
            hasAcceptanceCriteria: hasAcceptanceCriteria,
            updatedAt: t0
        )
    }

    static func file(_ path: String, blob: String = "a1b2c3") -> SuspiciousFile {
        SuspiciousFile(path: path, rule: .pattern, pattern: ".env*", sizeBytes: 212, blob: blob)
    }

    static func envelope(_ seq: Seq, _ event: JournalEvent, commandId: CommandID? = nil, projectId: ProjectID? = project) -> EventEnvelope {
        EventEnvelope(seq: seq, at: t0, projectId: projectId, commandId: commandId, event: event)
    }

    static func snapshot(
        seq: Seq = 10,
        tasks: [TaskCard] = [],
        projects: [ProjectSummary]? = nil,
        pipelines: [PipelineSummary]? = nil,
        openIncidents: Int = 0,
        stageLoad: [StageLoad] = []
    ) -> Snapshot {
        Snapshot(
            seq: seq,
            projects: projects ?? [project()],
            pipelines: pipelines ?? [pipeline()],
            tasks: tasks,
            openIncidentCount: openIncidents,
            stageLoad: stageLoad
        )
    }
}
