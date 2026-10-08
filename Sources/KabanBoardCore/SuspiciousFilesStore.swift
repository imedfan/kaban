import Foundation
import Observation
import KabanProtocol

public struct SuspiciousFilesContext: Codable, Equatable, Sendable {
    public let card: TaskCard
    public let pipeline: PipelineSummary
    public let files: [SuspiciousFile]
    public let bounceLimitTotal: Int?
    public let hasFrozenReturnPipeline: Bool
    public init?(detail: TaskDetail, pipeline: PipelineSummary?) {
        guard detail.task.state == .waitingHuman(.suspiciousFiles), let pipeline = detail.fileCheck?.returnPipeline ?? pipeline,
              pipeline.projectId == detail.task.projectId,
              pipeline.stages.contains(where: { $0.id == detail.task.stageId }),
              detail.suspiciousFiles == detail.task.suspiciousFiles else { return nil }
        card = detail.task; self.pipeline = pipeline; files = detail.suspiciousFiles
        bounceLimitTotal = detail.fileCheck?.bounceLimitTotal
        hasFrozenReturnPipeline = detail.fileCheck?.returnPipeline != nil
    }
    public var stage: StageSummary? { pipeline.stages.first { $0.id == card.stageId } }
    public var canReturn: Bool { hasFrozenReturnPipeline && (stage?.kind == .gate || stage?.kind == .merge) }
    public var targets: [StageSummary] { canReturn ? HumanReviewContext.returnTargets(card: card, pipeline: pipeline) : [] }
    public var defaultTarget: StageID? {
        let reported = stage?.kind == .gate ? stage?.onFail?.stage : stage?.onConflict?.stage
        return reported.flatMap { id in targets.contains { $0.id == id } ? id : nil }
    }
    public var removalText: String { "Убери из ветки: " + files.map(\.path).joined(separator: ", ") }
    public func returnCommand(current: Self?, comments: String, target: StageID?) -> Command? {
        guard self == current, canReturn, let target, targets.contains(where: { $0.id == target }), !comments.contains("\0") else { return nil }
        if comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .moveTask(taskId: card.id, stage: target) }
        return .requestChanges(taskId: card.id, comments: comments, target: target)
    }
    public static func canPreview(_ file: SuspiciousFile, check: SuspiciousFileCheck?) -> Bool {
        guard let check else { return false }
        return file.isText && file.sizeBytes >= 0 && file.sizeBytes < check.maxFileBytes
    }
}

@MainActor @Observable public final class SuspiciousFilesStore {
    public struct ReturnDraft: Codable, Equatable, Sendable {
        public let context: SuspiciousFilesContext
        public var comments = ""
        public var target: StageID?
        public var submittedBy: CommandID?
    }
    public private(set) var drafts: [ReturnDraft] = []
    public private(set) var storageError: String?
    private let session: BoardSession
    private let storage: any KeyValueStoring
    private let key: String
    public init(session: BoardSession, storage: any KeyValueStoring, key: String) {
        self.session = session; self.storage = storage; self.key = key
        do { drafts = try storage.data(forKey: key).map { try JSONDecoder().decode([ReturnDraft].self, from: $0) } ?? [] }
        catch { storageError = "Не удалось прочитать замечания о файлах. \(error.localizedDescription)" }
    }
    public func context(for id: TaskID) -> SuspiciousFilesContext? {
        guard session.selectedID == id, session.detailReadState == .loaded,
              let detail = session.detail, detail.task.id == id, detail.task == session.projection?.tasks[id] else { return nil }
        return .init(detail: detail, pipeline: session.projection?.pipelines[detail.task.projectId])
    }
    public func acceptance(for id: TaskID) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.last {
            if case .acceptSuspiciousFiles(let task, _) = $0.envelope.command { return task == id }; return false
        }
    }
    public func staleFiles(for id: TaskID) -> [FileBlobRef]? {
        guard let record = acceptance(for: id), case .rejected(let error) = record.phase,
              error.code == CommandError.staleSuspiciousFilesCode,
              case .acceptSuspiciousFiles(_, let files) = record.envelope.command else { return nil }
        return files
    }
    public func canAccept(_ context: SuspiciousFilesContext) -> Bool {
        self.context(for: context.card.id) == context && session.can(.acceptSuspiciousFiles(taskId: context.card.id, files: context.files.map { .init(path: $0.path, blob: $0.blob) }))
    }
    public func accept(_ context: SuspiciousFilesContext) async {
        guard canAccept(context) else { return }
        _ = await session.send(.acceptSuspiciousFiles(taskId: context.card.id, files: context.files.map { .init(path: $0.path, blob: $0.blob) }), editor: true)
        if staleFiles(for: context.card.id) != nil, session.selectedID == context.card.id { await session.retryDetail() }
    }
    public func draft(for id: TaskID) -> ReturnDraft? {
        if let saved = drafts.first(where: { $0.context.card.id == id }),
           returnReceipt(for: id)?.phase != .applied || context(for: id) == saved.context { return saved }
        return context(for: id).flatMap { $0.canReturn ? .init(context: $0, target: $0.defaultTarget) : nil }
    }
    public func returnReceipt(for id: TaskID) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        guard let command = drafts.first(where: { $0.context.card.id == id })?.submittedBy else { return nil }
        return session.journal?.records.first { $0.envelope.commandId == command }
    }
    public func edit(_ id: TaskID, comments: String? = nil, target: StageID? = nil) {
        guard storageError == nil, returnReceipt(for: id)?.isPending != true, var value = draft(for: id) else { return }
        if let comments { value.comments = comments }
        if let target { value.target = target }
        value.submittedBy = nil; save(value)
    }
    public func useCurrent(_ id: TaskID) {
        guard storageError == nil, returnReceipt(for: id)?.isPending != true, let current = context(for: id), current.canReturn else { return }
        let old = draft(for: id)
        var value = ReturnDraft(context: current, target: current.defaultTarget)
        value.comments = old?.comments ?? ""
        if let target = old?.target, current.targets.contains(where: { $0.id == target }) { value.target = target }
        save(value)
    }
    public func command(for id: TaskID) -> Command? {
        guard storageError == nil, let value = draft(for: id) else { return nil }
        return value.context.returnCommand(current: context(for: id), comments: value.comments, target: value.target)
    }
    public func canReturn(_ id: TaskID) -> Bool { command(for: id).map { session.can($0) } == true }
    public func submitReturn(_ id: TaskID) async {
        guard canReturn(id), var value = draft(for: id), let command = command(for: id) else { return }
        let envelope = CommandEnvelope(command: command)
        value.submittedBy = envelope.commandId; save(value)
        guard storageError == nil else { return }
        _ = await session.send(envelope, editor: true)
        if case .rejected(let error) = returnReceipt(for: id)?.phase,
           error.code == CommandError.invalidStateCode, session.selectedID == id { await session.retryDetail() }
    }
    private func save(_ value: ReturnDraft) {
        do {
            let next = drafts.filter { $0.context.card.id != value.context.card.id } + [value]
            storage.set(try JSONEncoder().encode(next), forKey: key); drafts = next
        } catch { storageError = "Не удалось сохранить замечание о файлах. \(error.localizedDescription)" }
    }
}
