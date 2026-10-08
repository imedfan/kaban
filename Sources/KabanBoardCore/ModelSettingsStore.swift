import Foundation
import Observation
import KabanProtocol

public enum ModelSelection {
    public static func selectable(_ model: ModelInfo, flags: [ModelFlag]) -> Bool {
        !model.forbidden && model.missingSince == nil && !model.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.id.rawValue.lowercased() != "auto"
            && !flags.contains { $0.modelId == model.id && $0.reason == .unavailable }
    }
    public static func family(_ model: ModelInfo) -> String {
        let id = model.id.rawValue.lowercased()
        if id.hasPrefix("composer") { return "Composer" }
        if id.hasPrefix("claude") || id.hasPrefix("opus") || id.hasPrefix("sonnet") || id.hasPrefix("haiku") { return "Claude" }
        if id.hasPrefix("gpt") { return "GPT" }
        if id.hasPrefix("gemini") { return "Gemini" }
        if id.hasPrefix("grok") { return "Grok" }
        if id.hasPrefix("deepseek") { return "DeepSeek" }
        if id.hasPrefix("kimi") { return "Kimi" }
        if id.hasPrefix("qwen") { return "Qwen" }
        return "Другие"
    }
}

@MainActor @Observable public final class ModelSettingsStore {
    public let session: BoardSession
    private let client: any KabanClient
    public private(set) var reading = false
    public private(set) var error: String?
    public private(set) var commandID: CommandID?
    public var catalog: [ModelInfo] { session.projection?.ephemeral.modelCatalog ?? [] }
    public var catalogKnown: Bool { session.projection?.ephemeral.modelCatalogKnown == true }
    public var rules: [ModelPoolRule]? { session.projection?.modelPoolRules }
    public var flags: [ModelFlag] { session.projection?.ephemeral.modelFlags ?? [] }
    public var receipt: ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.first { $0.envelope.commandId == commandID }
    }
    public init(client: any KabanClient, session: BoardSession) { self.client = client; self.session = session }
    public func can(_ command: Command) -> Bool { session.can(command) && session.pending(in: command.mutationScope ?? .global) == nil && !reading }
    public func loadIfNeeded() async {
        guard !catalogKnown, !reading, session.can(CommandName.listModels) else { return }
        reading = true; defer { reading = false }
        let generation = session.sessionGeneration, seq = session.projection?.stateSeq
        let envelope = CommandEnvelope(command: .listModels)
        do {
            let reply = try await client.send(envelope)
            guard session.sessionGeneration == generation, session.canSend, session.projection?.stateSeq == seq, !catalogKnown else { return }
            guard reply.commandId == envelope.commandId else { throw CommandError(code: "invalid_reply", message: "Ответ каталога относится к другой команде.") }
            if case .error(let failure) = reply.result { throw failure }
            guard case .models(let models) = reply.result else { throw CommandError(code: "invalid_reply", message: "Служба не вернула каталог моделей.") }
            session.projection?.acceptModelCatalog(models); error = nil
        } catch { if session.sessionGeneration == generation { self.error = (error as? CommandError)?.message ?? error.localizedDescription } }
    }
    @discardableResult public func send(_ command: Command) async -> Bool {
        guard can(command) else { return false }
        let envelope = CommandEnvelope(command: command)
        commandID = envelope.commandId; error = nil
        let accepted = await session.send(envelope)
        if !accepted { error = session.error ?? "Изменение не подтверждено. Проверьте исход команды." }
        return accepted
    }
}

@MainActor @Observable public final class TaskModelOverrideStore {
    nonisolated public let taskID: TaskID
    public let session: BoardSession
    public private(set) var card: TaskCard
    public private(set) var stages: [TaskModelStage]
    public private(set) var stageID: StageID
    public var model = ""
    public private(set) var commandID: CommandID?
    public private(set) var error: String?
    private var generation: UUID
    public var stage: TaskModelStage? { stages.first { $0.stageId == stageID } }
    public var receipt: ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.first { $0.envelope.commandId == commandID }
    }
    public var stale: Bool { session.sessionGeneration != generation || session.projection?.tasks[taskID] != card }
    public var pending: Bool { session.pending(in: .task(taskID)) != nil }
    public init?(detail: TaskDetail, session: BoardSession) {
        guard let stages = detail.modelStages, !stages.isEmpty, session.projection?.tasks[detail.task.id] == detail.task else { return nil }
        taskID = detail.task.id; card = detail.task; self.stages = stages; self.session = session
        stageID = stages.first { $0.stageId == detail.task.stageId }?.stageId ?? stages[0].stageId
        generation = session.sessionGeneration
        model = stages.first { $0.stageId == stageID }?.resolvedModel.rawValue ?? ""
    }
    public func selectStage(_ id: StageID) {
        guard let stage = stages.first(where: { $0.stageId == id }), !pending else { return }
        stageID = id; model = stage.resolvedModel.rawValue; error = nil
    }
    public func reconcile(_ detail: TaskDetail) {
        guard detail.task.id == taskID, session.projection?.tasks[taskID] == detail.task,
              let stages = detail.modelStages, stages.contains(where: { $0.stageId == stageID }), !pending else { return }
        card = detail.task; self.stages = stages; generation = session.sessionGeneration; error = nil
    }
    public func canSubmit(removing: Bool = false) -> Bool {
        guard !stale, !pending, let stage, ![.done, .cancelled].contains(card.state.status),
              session.can(.setModelOverride(taskId: taskID, stageId: stageID, model: removing ? nil : ModelID(rawValue: model))) else { return false }
        if removing { return stage.overrideModel != nil }
        let id = ModelID(rawValue: model)
        return stage.overrideModel != id && session.projection?.ephemeral.modelCatalog.contains {
            $0.id == id && ModelSelection.selectable($0, flags: session.projection?.ephemeral.modelFlags ?? [])
        } == true
    }
    @discardableResult public func submit(removing: Bool = false) async -> Bool {
        guard canSubmit(removing: removing) else { return false }
        let envelope = CommandEnvelope(command: .setModelOverride(taskId: taskID, stageId: stageID, model: removing ? nil : ModelID(rawValue: model)))
        commandID = envelope.commandId; error = nil
        let accepted = await session.send(envelope)
        if !accepted { error = session.error ?? "Изменение модели не подтверждено; выбор сохранён." }
        return accepted
    }
}
