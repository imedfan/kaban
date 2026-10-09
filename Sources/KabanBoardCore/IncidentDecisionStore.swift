import Foundation
import Observation
import KabanProtocol

public struct IncidentDecisionContext: Codable, Equatable, Sendable {
    public let incident: Incident
    public let card: TaskCard
    public let pipeline: PipelineSummary
    public init?(incident: Incident, detail: TaskDetail) {
        guard incident.resolvedAt == nil, incident.kind.isKnown,
              incident.taskId == detail.task.id, incident.projectId == detail.task.projectId,
              detail.task.state == .waitingHuman(.incident),
              let pipeline = detail.incidentPipeline, pipeline.projectId == incident.projectId,
              pipeline.versionHash?.isEmpty == false, pipeline.isValid,
              Set(pipeline.stages.map(\.id)).count == pipeline.stages.count,
              pipeline.stages.contains(where: { $0.id == detail.task.stageId }) else { return nil }
        self.incident = incident; card = detail.task; self.pipeline = pipeline
    }
    public var targets: [StageSummary] {
        pipeline.stages.filter { $0.id == card.stageId && $0.kind == .agent && !$0.readOnly }
            + HumanReviewContext.returnTargets(card: card, pipeline: pipeline)
    }
    public var defaultTarget: StageID? {
        pipeline.defaultReturnStage.flatMap { id in targets.contains { $0.id == id } ? id : nil }
    }
    public func command(current: Self?, target: StageID?, comments: String) -> Command? {
        guard self == current, let target, targets.contains(where: { $0.id == target }),
              !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !comments.contains("\0") else { return nil }
        return .requestChanges(taskId: card.id, comments: comments, target: target)
    }
}

@MainActor @Observable public final class IncidentDecisionStore {
    public struct Draft: Codable, Equatable, Sendable {
        public let context: IncidentDecisionContext
        public var comments = ""
        public var target: StageID?
        public var submittedBy: CommandID?
    }
    public private(set) var records: [Draft] = []
    public private(set) var storageError: String?
    private let session: BoardSession
    private let incidents: IncidentsStore
    private let storage: any KeyValueStoring
    private let key: String
    public init(session: BoardSession, incidents: IncidentsStore, storage: any KeyValueStoring, key: String) {
        self.session = session; self.incidents = incidents; self.storage = storage; self.key = key
        do { records = try storage.data(forKey: key).map { try JSONDecoder().decode([Draft].self, from: $0) } ?? [] }
        catch { storageError = "Не удалось прочитать черновики решений. \(error.localizedDescription)" }
    }
    public func currentContext(_ id: IncidentID) -> IncidentDecisionContext? {
        guard incidents.isCurrent, let incident = incidents.records.first(where: { $0.id == id }),
              session.selectedID == incident.taskId, let detail = session.detail,
              detail.task == session.projection?.tasks[incident.taskId] else { return nil }
        return .init(incident: incident, detail: detail)
    }
    public func receipt(_ id: IncidentID) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        guard let command = records.first(where: { $0.context.incident.id == id })?.submittedBy else { return nil }
        return session.journal?.records.first { $0.envelope.commandId == command }
    }
    public func draft(_ id: IncidentID) -> Draft? {
        if let saved = records.first(where: { $0.context.incident.id == id }) { return saved }
        return currentContext(id).map { .init(context: $0, target: $0.defaultTarget) }
    }
    public func canSubmit(_ id: IncidentID) -> Bool {
        guard storageError == nil, session.can(.requestChanges), session.detailReadState == .loaded,
              let draft = draft(id), receipt(id)?.phase != .applied,
              session.pending(in: .task(draft.context.card.id)) == nil else { return false }
        return draft.context.command(current: currentContext(id), target: draft.target, comments: draft.comments) != nil
    }
    public func edit(_ id: IncidentID, comments: String? = nil, target: StageID? = nil) {
        guard storageError == nil, receipt(id)?.isPending != true, var draft = draft(id) else { return }
        if let comments { draft.comments = comments }; if let target { draft.target = target }
        draft.submittedBy = nil; save(draft)
    }
    public func useCurrent(_ id: IncidentID) {
        guard storageError == nil, receipt(id)?.isPending != true, session.detailReadState == .loaded,
              let context = currentContext(id) else { return }
        let old = draft(id)
        var next = Draft(context: context, target: context.defaultTarget)
        next.comments = old?.comments ?? ""
        if let target = old?.target { next.target = context.targets.contains { $0.id == target } ? target : nil }
        save(next)
    }
    private func save(_ draft: Draft) {
        do {
            let next = records.filter { $0.context.incident.id != draft.context.incident.id } + [draft]
            storage.set(try JSONEncoder().encode(next), forKey: key); records = next
        } catch { storageError = "Не удалось сохранить замечание. \(error.localizedDescription)" }
    }
    @discardableResult public func submit(_ id: IncidentID) async -> Bool {
        guard canSubmit(id), var draft = draft(id),
              let command = draft.context.command(current: currentContext(id), target: draft.target, comments: draft.comments) else { return false }
        let envelope = CommandEnvelope(command: command)
        draft.submittedBy = envelope.commandId; save(draft)
        guard storageError == nil else { return false }
        let sent = await session.send(envelope, editor: true)
        if case .rejected(let failure) = receipt(id)?.phase, failure.code == CommandError.invalidStateCode {
            await session.retryDetail(); incidents.scheduleRefresh()
        }
        return sent
    }
}
