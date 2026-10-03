import Foundation
@testable import KabanProtocol

/// Эталонные значения для фикстур. Фикстуры — контракт для фейкового драйвера (бэк) и мок-клиента (фронт).
enum Samples {
    static let t0 = Date(timeIntervalSince1970: 1_791_100_800) // 2026-10-04T08:00:00Z
    static let cmd = UUID(uuidString: "6F1C2B9E-6C1A-4C2E-9E0B-7A2F7B0C1D01")!
    static let project: ProjectID = "p-kaban"

    static let stages: [StageSummary] = [
        StageSummary(id: "backlog", name: "Backlog", kind: .queue, display: StageDisplay(icon: "tray", order: 0)),
        StageSummary(id: "dev", name: "Разработка", kind: .agent, display: StageDisplay(icon: "hammer", color: "blue", order: 1),
                     wip: 3, model: "claude-4.5-opus", onSuccess: "test", maxAttempts: 3),
        StageSummary(id: "test", name: "Тесты", kind: .agent, display: StageDisplay(order: 2), wip: 2, model: "composer-1",
                     returnsTo: [StageReturn(stage: "dev", limit: 3)], onSuccess: "review", maxAttempts: 3),
        StageSummary(id: "review", name: "Human Review", kind: .human, display: StageDisplay(order: 3), onSuccess: "merge"),
        StageSummary(id: "merge", name: "Слияние", kind: .merge, display: StageDisplay(order: 4), wip: 1, onSuccess: "done"),
        StageSummary(id: "done", name: "Готово", kind: .terminal, display: StageDisplay(order: 5)),
    ]

    static let pipeline = PipelineSummary(projectId: project, versionHash: "sha256:9f2c", gitPreset: .standard, stages: stages,
        issues: [ValidationIssue(path: "stages[1].agent.mcp[1]", code: ValidationCode.mcpNotAllowlisted,
                                 message: "Сервер «linear» выключен в белом списке проекта и не будет подключён", severity: .warning)])

    static let invalidPipeline = PipelineSummary(projectId: "p-site", versionHash: nil, stages: [
        StageSummary(id: "dev", name: "Разработка", kind: .agent, display: StageDisplay(order: 1), wip: 1, model: nil),
    ], issues: [ValidationIssue(path: "stages[0].agent.model", code: ValidationCode.modelMissing,
                                message: "У стадии нет модели", severity: .error)])

    static func card(_ id: TaskID, stage: StageID, state: TaskState, title: String) -> TaskCard {
        TaskCard(id: id, projectId: project, title: title, stageId: stage, state: state, branch: "kaban/\(id)-x",
                 attempt: 1, maxAttempts: 3, runsSinceHuman: 2, model: "claude-4.5-opus", updatedAt: t0)
    }

    static let tasks: [TaskCard] = [
        card("t-1", stage: "dev", state: .running, title: "Парсер stream-json"),
        card("t-2", stage: "dev", state: .queued(.wipFull), title: "Ждёт места"),
        card("t-3", stage: "test", state: .queued(.quotaCm), title: "Ждёт квоту Cm"),
        card("t-4", stage: "dev", state: .retryWait(.silentExit), title: "Молчаливый выход"),
        card("t-5", stage: "dev", state: .waitingHuman(.modelSubstituted), title: "Подмена модели"),
        card("t-6", stage: "dev", state: .waitingHuman(.runLimit), title: "Лимит запусков"),
        card("t-7", stage: "review", state: .waitingHuman(.review), title: "На ревью"),
        { var c = card("t-8", stage: "test", state: .waitingHuman(.suspiciousFiles), title: "Подозрительные файлы"); c.suspiciousFiles = suspicious; return c }(),
        card("t-9", stage: "merge", state: .blocked(.mainDirty), title: "main грязный"),
        card("t-10", stage: "done", state: .done, title: "Готово"),
    ]

    static let flags: [SchedulerFlag] = [
        .poolUsageExhausted(.om, resetsAt: Date(timeIntervalSince1970: 1_792_195_200)),
        .usageExhaustedUnknown(resetsAt: nil),
        .rateLimited(cooldownUntil: t0.addingTimeInterval(900), step: 1),
        .runnerUnavailable(.agentNotLoggedIn),
        .projectUnavailable("p-site", .pipelineInvalid, detail: "dev: нет модели"),
        .projectUnavailable(project, .mcpUnexpected, detail: "github"),
        .intakePaused(project),
        .mergeBlocked(project),
    ]

    static let modelFlags: [ModelFlag] = [
        ModelFlag(modelId: "claude-4.5-opus", reason: .substituted, requested: "Claude 4.5 Opus", actual: "Claude 4 Sonnet",
                  fallbackModel: "claude-4-sonnet", since: t0),
        ModelFlag(modelId: "gpt-5-codex", reason: .unavailable, requested: "GPT-5 Codex", since: t0),
    ]

    static let quota = QuotaState(cm: 42.5, om: nil, billingCycleEnd: Date(timeIntervalSince1970: 1_792_195_200), fetchedAt: t0)

    static let snapshot = Snapshot(seq: 1042,
        projects: [ProjectSummary(id: project, name: "kaban", path: "/Users/artem/dev/kaban", mascotSeed: "p-kaban"),
                   ProjectSummary(id: "p-site", name: "site", path: "/Users/artem/dev/site", availability: .missing, mascotSeed: "p-site")],
        pipelines: [pipeline, invalidPipeline], tasks: tasks, schedulerFlags: flags, modelFlags: modelFlags, quota: quota, openIncidentCount: 1)

    static let suspicious = [SuspiciousFile(path: ".env.local", rule: .pattern, pattern: ".env*", sizeBytes: 212, blob: "a1b2c3"),
                             SuspiciousFile(path: "assets/dump.bin", rule: .size, sizeBytes: 7_340_032, blob: "d4e5f6")]

    static let events: [EventEnvelope] = [
        EventEnvelope(seq: 1043, at: t0, projectId: project, commandId: nil, event: .taskTransitioned(
            TaskTransition(taskId: "t-1", fromStage: "dev", toStage: "test", from: .gating, to: .queued(nil), by: .daemon, runId: "r-11"))),
        EventEnvelope(seq: 1044, at: t0, projectId: project, commandId: cmd, event: .humanAnswered(
            HumanAnswer(taskId: "t-6", requestId: nil, text: "Разбей задачу на две"))),
        EventEnvelope(seq: 1045, at: t0, projectId: project, event: .gitDenied(
            GitDenied(denialId: "d-1", taskId: "t-1", runId: "r-11", argv: ["git", "rebase", "main"], rule: "preset:standard"))),
        EventEnvelope(seq: 1046, at: t0, projectId: project, event: .gitGrantDelivered(GitGrantDelivered(grantId: "g-1", runId: "r-11", via: .mcpResponse))),
        EventEnvelope(seq: 1047, at: t0, projectId: project, event: .suspiciousFilesFound(
            SuspiciousFilesFound(taskId: "t-8", runId: "r-12", stageId: "test", files: suspicious))),
        EventEnvelope(seq: 1048, at: t0, projectId: project, commandId: cmd, event: .suspiciousFilesAccepted(
            SuspiciousFilesAccepted(taskId: "t-8", files: suspicious, by: .human, commandId: cmd))),
        EventEnvelope(seq: 1049, at: t0, projectId: project, event: .incidentOpened(
            Incident(id: "i-1", projectId: project, taskId: "t-9", runId: "r-13", kind: .refsMoved, rolledBack: ["refs/heads/main"], openedAt: t0))),
        EventEnvelope(seq: 1050, at: t0, projectId: project, event: .gitPolicyUpdated(
            GitPolicyUpdated(projectId: project, scope: .stage("dev"), pipelineVersion: "sha256:9f2d"))),
    ]

    static let ephemeral: [EphemeralEvent] = [
        .quotaUpdated(quota),
        .quotaUpdated(QuotaState(cm: nil, om: nil, billingCycleEnd: nil, fetchedAt: t0)), // «нет данных»
        .schedulerFlagsChanged(flags),
        .modelFlagsChanged(modelFlags),
        .resyncRequired,
    ]

    static let commands: [CommandEnvelope] = [
        CommandEnvelope(commandId: cmd, command: .answerHuman(taskId: "t-6", text: "Разбей задачу на две", requestId: nil)),
        CommandEnvelope(commandId: cmd, command: .cancelTask(taskId: "t-2", keepBranch: true)),
        CommandEnvelope(commandId: cmd, command: .reject(taskId: "t-7", target: .stage(stageId: "dev"), keepBranch: false)),
        CommandEnvelope(commandId: cmd, command: .addDenialToPolicy(denialId: "d-1", scope: .project)),
        CommandEnvelope(commandId: cmd, command: .recheck(scope: .project(projectId: "p-site"))),
        CommandEnvelope(commandId: cmd, command: .setQuotaOptions(options: QuotaOptions(enabled: true, consent: true))),
        CommandEnvelope(commandId: cmd, command: .listIncidents(projectIds: nil, state: .open)),
        CommandEnvelope(commandId: cmd, command: .pauseAll),
        CommandEnvelope(commandId: cmd, command: .acceptSuspiciousFiles(taskId: "t-8", files: suspicious.map { FileBlobRef(path: $0.path, blob: $0.blob) })),
    ]

    static let taskDetail = TaskDetail(seq: 1047, task: tasks[7], feed: [], runs: [], suspiciousFiles: suspicious,
                                       acceptedFiles: [AcceptedFile(path: "fixtures/big.bin", blob: "0f0f0f", at: t0, commandId: cmd)])
}
