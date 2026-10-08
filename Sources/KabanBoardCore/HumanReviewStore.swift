import Foundation
import Observation
import KabanProtocol

public enum HumanReviewDecision: String, Codable, Sendable { case approve, requestChanges, reject }

/// A decision is bound to the result and pipeline the reviewer actually saw.
public struct HumanReviewContext: Codable, Equatable, Sendable {
    public let card: TaskCard
    public let pipeline: PipelineSummary
    public let artifacts: [TaskArtifact]
    public let runs: [RunSummary]
    public let clonePath: String?
    public init?(detail: TaskDetail, pipeline: PipelineSummary?) {
        guard let pipeline, pipeline.projectId == detail.task.projectId,
              let stage = pipeline.stages.first(where: { $0.id == detail.task.stageId }),
              (detail.task.state == .waitingHuman(.review) && stage.kind == .human)
                || (detail.task.state == .waitingHuman(.conflictLimit) && stage.kind == .merge) else { return nil }
        card = detail.task; self.pipeline = pipeline
        artifacts = detail.artifacts; runs = detail.runs; clonePath = detail.clonePath
    }
    /// Advisory choices follow on_success, independently of board display order.
    /// The daemon validates the command again; the client never resolves a default.
    public static func returnTargets(card: TaskCard, pipeline: PipelineSummary) -> [StageSummary] {
        guard pipeline.projectId == card.projectId,
              Set(pipeline.stages.map(\.id)).count == pipeline.stages.count else { return [] }
        let stages = Dictionary(uniqueKeysWithValues: pipeline.stages.map { ($0.id, $0) })
        return pipeline.stages.filter { candidate in
            guard candidate.kind == .agent, !candidate.readOnly, candidate.id != card.stageId else { return false }
            var seen: Set<StageID> = [candidate.id], next = candidate.onSuccess
            while let id = next {
                if id == card.stageId { return true }
                guard seen.insert(id).inserted, let stage = stages[id] else { return false }
                next = stage.onSuccess
            }
            return false
        }
    }
    public var targets: [StageSummary] { Self.returnTargets(card: card, pipeline: pipeline) }
    public var defaultTarget: StageID? {
        let source = pipeline.stages.first { $0.id == card.stageId }
        let reported = source?.kind == .merge ? source?.onConflict?.stage : pipeline.defaultReturnStage
        return reported.flatMap { id in targets.contains { $0.id == id } ? id : nil }
    }
    public func command(_ decision: HumanReviewDecision, current: HumanReviewContext?, comments: String,
                        target: StageID?, cancel: Bool, keepBranch: Bool) -> Command? {
        guard self == current else { return nil }
        switch decision {
        case .approve:
            guard card.state == .waitingHuman(.review),
                  pipeline.stages.first(where: { $0.id == card.stageId })?.kind == .human,
                  let next = pipeline.stages.first(where: { $0.id == card.stageId })?.onSuccess,
                  pipeline.stages.contains(where: { $0.id == next }) else { return nil }
            return .approve(taskId: card.id)
        case .requestChanges:
            guard defaultTarget != nil, let target, targets.contains(where: { $0.id == target }),
                  !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !comments.contains("\0") else { return nil }
            return .requestChanges(taskId: card.id, comments: comments, target: target)
        case .reject:
            if cancel { return .reject(taskId: card.id, target: .cancel, keepBranch: keepBranch) }
            guard let target, targets.contains(where: { $0.id == target }) else { return nil }
            return .reject(taskId: card.id, target: .stage(stageId: target), keepBranch: false)
        }
    }
}

@MainActor @Observable public final class HumanReviewStore {
    public struct Draft: Codable, Equatable, Sendable {
        public let context: HumanReviewContext
        public var comments = ""
        public var target: StageID?
        public var cancel = true
        public var keepBranch = false
        public var submittedBy: CommandID?
    }
    public private(set) var records: [Draft] = []
    public private(set) var storageError: String?
    private let session: BoardSession
    private let storage: any KeyValueStoring
    private let key: String
    public init(session: BoardSession, storage: any KeyValueStoring, key: String) {
        self.session = session; self.storage = storage; self.key = key
        do { records = try storage.data(forKey: key).map { try JSONDecoder().decode([Draft].self, from: $0) } ?? [] }
        catch { storageError = "Не удалось прочитать черновики ревью. \(error.localizedDescription)" }
    }
    public func currentContext(for id: TaskID) -> HumanReviewContext? {
        guard session.selectedID == id, let detail = session.detail, detail.task.id == id,
              detail.task == session.projection?.tasks[id] else { return nil }
        return .init(detail: detail, pipeline: session.projection?.pipelines[detail.task.projectId])
    }
    public func record(for id: TaskID) -> Draft? { records.first { $0.context.card.id == id } }
    public func receipt(for id: TaskID) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        guard let command = record(for: id)?.submittedBy else { return nil }
        return session.journal?.records.first { $0.envelope.commandId == command }
    }
    public func draft(for id: TaskID) -> Draft? {
        if let saved = record(for: id), receipt(for: id)?.phase != .applied || currentContext(for: id) == saved.context { return saved }
        return currentContext(for: id).map { Draft(context: $0, target: $0.defaultTarget) }
    }
    public func isStale(_ id: TaskID) -> Bool { draft(for: id).map { $0.context != currentContext(for: id) } ?? false }
    public func canSubmit(_ decision: HumanReviewDecision, for id: TaskID) -> Bool {
        let name: CommandName = decision == .approve ? .approve : decision == .requestChanges ? .requestChanges : .reject
        guard storageError == nil, session.can(name), session.detailReadState == .loaded,
              session.pending(in: .task(id)) == nil, let draft = draft(for: id),
              receipt(for: id)?.phase != .applied || draft.submittedBy == nil else { return false }
        return draft.context.command(decision, current: currentContext(for: id), comments: draft.comments,
                                     target: draft.target, cancel: draft.cancel, keepBranch: draft.keepBranch) != nil
    }
    public func edit(_ id: TaskID, comments: String? = nil, target: StageID? = nil, cancel: Bool? = nil, keepBranch: Bool? = nil) {
        guard storageError == nil, receipt(for: id)?.isPending != true, var draft = draft(for: id) else { return }
        if let comments { draft.comments = comments }
        if let target { draft.target = target }
        if let cancel { draft.cancel = cancel }
        if let keepBranch { draft.keepBranch = keepBranch }
        draft.submittedBy = nil; save(draft)
    }
    /// Explicitly review the updated result before reusing the saved comment.
    public func useCurrentReview(_ id: TaskID) {
        guard storageError == nil, receipt(for: id)?.isPending != true, session.detailReadState == .loaded,
              let current = currentContext(for: id) else { return }
        let old = draft(for: id)
        var draft = Draft(context: current, target: current.defaultTarget)
        draft.comments = old?.comments ?? ""; draft.cancel = old?.cancel ?? true; draft.keepBranch = old?.keepBranch ?? false
        if let target = old?.target { draft.target = current.targets.contains { $0.id == target } ? target : nil }
        save(draft)
    }
    private func save(_ draft: Draft) {
        do {
            let next = records.filter { $0.context.card.id != draft.context.card.id } + [draft]
            storage.set(try JSONEncoder().encode(next), forKey: key); records = next
        } catch { storageError = "Не удалось сохранить комментарий. \(error.localizedDescription)" }
    }
    @discardableResult public func submit(_ decision: HumanReviewDecision, for id: TaskID) async -> Bool {
        guard canSubmit(decision, for: id), var draft = draft(for: id),
              let command = draft.context.command(decision, current: currentContext(for: id), comments: draft.comments,
                                                  target: draft.target, cancel: draft.cancel, keepBranch: draft.keepBranch) else { return false }
        let envelope = CommandEnvelope(command: command)
        draft.submittedBy = envelope.commandId; save(draft)
        guard storageError == nil else { return false }
        let sent = await session.send(envelope, editor: true)
        if case .rejected(let failure) = receipt(for: id)?.phase,
           failure.code == CommandError.invalidStateCode, session.selectedID == id { await session.retryDetail() }
        return sent
    }
}
