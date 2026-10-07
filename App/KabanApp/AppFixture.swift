import Foundation
import KabanProtocol
import KabanBoardCore

/// Display fixtures use the same DTOs and mock transport as the eventual daemon.
@MainActor enum AppFixture {
    static func client() -> MockKabanClient {
        let now = Date()
        var stages: [StageSummary] = [
            .init(id: "backlog", name: "Backlog", kind: .queue, display: .init(order: 0), onSuccess: "dev"),
            .init(id: "dev", name: "Dev", kind: .agent, display: .init(order: 1), wip: 3, model: "composer-1", onSuccess: "test", maxAttempts: 3),
            .init(id: "test", name: "Test", kind: .agent, display: .init(icon: "flask", order: 2), wip: 2, model: "sonnet-4.5", readOnly: true, onSuccess: "ai-review", maxAttempts: 3),
            .init(id: "ai-review", name: "AI Review", kind: .agent, display: .init(order: 3), wip: 2, model: "opus-4.5", readOnly: true, onSuccess: "review", maxAttempts: 3),
            .init(id: "review", name: "Human Review", kind: .human, display: .init(order: 4), wip: 5, onSuccess: "merge"),
            .init(id: "merge", name: "Merge", kind: .merge, display: .init(order: 5), onSuccess: "done", onConflict: .init(stage: "dev", limit: 2)),
            .init(id: "done", name: "Done", kind: .terminal, display: .init(order: 6))
        ]
        let boardMatrix = BoardQA.argument("--qa-board") == "matrix"
        if boardMatrix {
            for index in 2..<stages.count { stages[index].display.order += 1 }
            stages.insert(.init(id: "checks", name: "Checks", kind: .gate, display: .init(order: 2), gates: ["swift test"], onFail: .init(stage: "dev", limit: 3)), at: 2)
            stages.append(.init(id: "archive", name: "Архив", kind: .terminal, display: .init(order: 9, hidden: true)))
            stages[stages.firstIndex(where: { $0.id == "done" })!].display.collapsed = true
        }
        let specs: [(String, String, Int, EdgeTexture)] = [("shop", "shop-api", 0, .solidThin), ("kaban", "kaban", 1, .stripes), ("mobile", "mobile-app", 22, .dots), ("docs", "docs-site", 2, .grid)]
        var projects = specs.map { id, name, index, texture in
            ProjectSummary(id: .init(rawValue: id), name: name, path: "~/Projects/" + name, mascotSeed: MascotKit.seed(for: id, mascotIndex: index, texture: texture) ?? id)
        }
        func card(_ id: String, _ project: ProjectID, _ title: String, _ stage: StageID, _ state: TaskState, attempt: Int = 0, files: [SuspiciousFile] = []) -> TaskCard {
            .init(id: .init(rawValue: id), projectId: project, title: title, stageId: stage, state: state,
                  branch: stage == "backlog" ? nil : "kaban/" + id.lowercased(), attempt: attempt, maxAttempts: attempt > 0 ? 3 : nil,
                  model: stages.first { $0.id == stage }?.model, suspiciousFiles: files, hasAcceptanceCriteria: true, updatedAt: now)
        }
        var tasks = [
            card("SHOP-58", "shop", "Экспорт заказов в CSV", "backlog", .queued(nil)),
            card("SHOP-61", "shop", "Rate limit на /auth/login", "backlog", .queued(nil)),
            card("SHOP-42", "shop", "Пагинация курсором в /orders", "dev", .running, attempt: 2),
            card("SHOP-44", "shop", "Цены в копейках во всём API", "dev", .retryWait(.gateFailed), attempt: 2),
            card("SHOP-52", "shop", "Интеграция платёжного шлюза", "dev", .waitingHuman(.suspiciousFiles), files: [
                .init(path: ".env.local", rule: .pattern, pattern: ".env*", sizeBytes: 412, isText: true, blob: "fixture-env"),
                .init(path: "exports/orders-dump.sql", rule: .size, sizeBytes: 9_300_000, isText: true, blob: "fixture-dump")
            ]),
            card("SHOP-39", "shop", "Повтор вебхуков оплаты", "test", .queued(.quotaOm)),
            card("SHOP-40", "shop", "Валидация адреса доставки", "test", .queued(nil)),
            card("SHOP-35", "shop", "Кэш каталога в Redis", "ai-review", .waitingHuman(.modelSubstituted)),
            card("SHOP-34", "shop", "Логи запросов без PII", "ai-review", .queued(nil)),
            card("SHOP-31", "shop", "Слияние гостевой корзины", "review", .waitingHuman(.review)),
            card("SHOP-29", "shop", "Индексы поиска по SKU", "merge", .gating),
            card("SHOP-27", "shop", "Healthcheck сервиса", "done", .done),
            card("KBN-21", "kaban", "Справочник моделей: обновление каталога", "backlog", .queued(nil)),
            card("KBN-15", "kaban", "Дорожки: закреплённые заголовки", "dev", .running, attempt: 1),
            card("KBN-14", "kaban", "Квота: свежесть данных перед стартом", "test", .queued(nil)),
            card("KBN-10", "kaban", "XPC: досылка событий по seq", "review", .waitingHuman(.review))
        ]
        if boardMatrix {
            projects[0].openIncidentCount = 1
            tasks[2].unusedGitGrants = 2; tasks[2].bounceByReason = ["test_dev": 2, "merge_conflict": 1]
            tasks[2].overlapsWith = ["SHOP-44", "KBN-15"]
            tasks[3].retryAt = now.addingTimeInterval(90)
            tasks.append(card("SHOP-GATE", "shop", "Проверки перед ревью", "checks", .gating))
            tasks.append(card("SHOP-HIDDEN", "shop", "Задача из скрытого архива", "archive", .done))
            tasks.append(card("DOCS-SAME-ID", "docs", "Тот же id, другая стадия", "test", .paused))
            for (index, reason) in WaitingHumanReason.allCases.enumerated() {
                tasks.append(card("WAIT-\(index)", "shop", "Причина ожидания: \(reason.rawValue)", "ai-review", .waitingHuman(reason)))
            }
            for (index, reason) in RetryWaitReason.allCases.enumerated() {
                var value = card("RETRY-\(index)", "shop", "Причина повтора: \(reason.rawValue)", "dev", .retryWait(reason), attempt: 2)
                value.retryAt = now.addingTimeInterval(120); tasks.append(value)
            }
            for index in 0..<40 {
                var value = card("LONG-\(index)", "shop", "Длинная очередь: проверка композиции карточки и независимой прокрутки столбца \(index)", "backlog", .queued(nil))
                if index == 0 { value.hasAcceptanceCriteria = false }; tasks.append(value)
            }
        }
        let state = BoardQA.argument("--qa-state")
        if state == "long" {
            tasks[2].title = "Очень длинное название задачи: пагинация, фильтрация и согласованная обработка заказов для нескольких международных магазинов"
            tasks[2].id = .init(rawValue: "SHOP-VERY-LONG-IDENTIFIER-2026-1042")
        }
        if state == "empty" { tasks = [] }
        var kabanStages = stages
        kabanStages[kabanStages.firstIndex(where: { $0.id == "test" })!].model = nil
        let pipelines = projects.map { project in
            var projectStages = project.id == "kaban" ? kabanStages : stages
            if boardMatrix && project.id == "docs", let index = projectStages.firstIndex(where: { $0.id == "test" }) {
                projectStages[index].kind = .human; projectStages[index].name = "Редактор"; projectStages[index].model = nil
            }
            return PipelineSummary(projectId: project.id, versionHash: "local-fixture", stages: projectStages,
                            issues: project.id == "kaban" ? [.init(path: "stages[2].model", stageId: "test", code: "model_missing", message: "не задана модель у Test", severity: .error)] : [], defaultReturnStage: "dev")
        }
        let loads = projects.flatMap { project in
            stages.compactMap { stage -> StageLoad? in
                guard let limit = stage.wip else { return nil }
                if boardMatrix && project.id == "shop" && stage.id == "test" { return nil }
                return .init(projectId: project.id, stageId: stage.id, wipUsed: tasks.filter { $0.projectId == project.id && $0.stageId == stage.id && $0.state.status.occupiesWIP(in: stage.kind) }.count, wipLimit: boardMatrix && project.id == "shop" && stage.id == "dev" ? 1 : limit)
            }
        }
        let bodies = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, "## Описание\n\n\($0.title).\n\n## Критерии приёмки\n\n- Существующее поведение сохранено.\n- Граничные случаи проверены.\n- Изменения готовы к ревью.") })
        var runs: [TaskID: [RunSummary]] = [:]
        var current: [EphemeralEvent] = []
        if boardMatrix {
            let run = RunSummary(id: "fixture-current-run", taskId: "SHOP-42", stageId: "dev", number: 2, status: .running, requestedModel: "composer-1", startedAt: now.addingTimeInterval(-120))
            runs["SHOP-42"] = [run]
            current = [.runProgress(.init(runId: run.id, taskId: run.taskId, message: "Добавлены проверки границ курсора", lastActivityAt: now))]
            runs["SHOP-35"] = [.init(id: "fixture-substitution", taskId: "SHOP-35", stageId: "ai-review", number: 1, status: .failed, requestedModel: "opus-4.5", actualModelName: "Sonnet 4", countsTowardLimits: false, startedAt: now.addingTimeInterval(-180), endedAt: now)]
        }
        return MockKabanClient(snapshot: .init(seq: 0, projects: projects, pipelines: pipelines, tasks: tasks, openIncidentCount: projects.reduce(0) { $0 + $1.openIncidentCount }, stageLoad: loads), taskBodies: bodies, taskRuns: runs, currentEvents: current)
    }
}

/// Explicit read fixtures for the real onboarding WindowGroup. They never
/// execute/configure Cursor or claim that a helper was installed.
@MainActor final class QAEnvironmentClient: KabanClient {
    let base: MockKabanClient
    let state: String
    init(base: MockKabanClient, state: String) { self.base = base; self.state = state }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities {
        var value = try await base.capabilities()
        for command in [CommandName.checkEnvironment, .getCursorEnvironment] {
            value.commands.removeAll { $0.name == command.rawValue }
            value.commands.append(.init(name: command.rawValue, support: .supported))
        }
        return value
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        let path = "/Users/local/Library/Application Support/Очень длинное название каталога проекта/Cursor CLI/bin/cursor-agent"
        let result: CommandResult
        switch envelope.command {
        case .getCursorEnvironment: result = .cursorEnvironment(.init(executablePath: path))
        case .checkEnvironment:
            result = .environment(.init(cursorAgentPath: state == "missing" ? nil : path,
                version: state == "missing" ? nil : "2026.10.05-fixture", authOK: state == "ready",
                gitVersion: state == "toolchain" ? nil : "git 2.53.0 (fixture)", sandboxOK: state != "toolchain", notificationsAuthorized: false))
        default: return try await base.send(envelope)
        }
        return .init(commandId: envelope.commandId, seq: nil, result: result)
    }
}

/// Opt-in refusal/pending replies for rendering the actual project sheet.
/// Does not register projects or emulate git/pipeline work.
@MainActor final class QAProjectClient: KabanClient {
    let base: MockKabanClient
    let state: String
    init(base: MockKabanClient, state: String) { self.base = base; self.state = state }
    func getSnapshot() async throws -> Snapshot { try await base.getSnapshot() }
    func synchronize() async throws -> SnapshotReplacement { try await base.synchronize() }
    func updates() -> AsyncThrowingStream<KabanClientUpdate, Error> { base.updates() }
    func events() -> AsyncStream<EventEnvelope> { base.events() }
    func capabilities() async throws -> DaemonCapabilities {
        var value = try await base.capabilities()
        value.commands.removeAll { $0.name == CommandName.addProject.rawValue }
        value.commands.append(.init(name: CommandName.addProject.rawValue, support: .supported))
        return value
    }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        guard case .addProject(_, _, let identity) = envelope.command else { return try await base.send(envelope) }
        let result: CommandResult
        if state == "pending" { result = .ok }
        else if state == "non-git" { result = .error(.init(code: "not_git_repository", message: "Выбранная папка не является git-репозиторием. Выберите корень репозитория и повторите добавление.")) }
        else if state == "invalid" { result = .error(.init(code: "identity_required", message: IdentityDraft.generalText, params: ["invalid": "name", "email": "developer@example.test"])) }
        else if identity != nil { result = .error(.init(code: "identity_required", message: IdentityDraft.generalText, params: ["missing": "email"])) }
        else { result = .error(.init(code: "identity_required", message: IdentityDraft.generalText, params: ["missing": "email", "name": "Автор проекта"])) }
        return .init(commandId: envelope.commandId, seq: result == .ok ? 0 : nil, result: result)
    }
}
