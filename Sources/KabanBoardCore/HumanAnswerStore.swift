import Foundation
import Observation
import KabanProtocol

/// The text remains addressed to the question and stage the person reviewed.
/// A replacement read cannot silently turn an answer into a note or retarget it.
public struct HumanAnswerContext: Codable, Equatable, Sendable {
    public let card: TaskCard
    public let request: HumanRequest?
    public init?(detail: TaskDetail, pipeline: PipelineSummary?) {
        let source = detail.task.state == .waitingHuman(.suspiciousFiles) ? detail.fileCheck?.returnPipeline ?? pipeline : pipeline
        guard case .waitingHuman(let reason) = detail.task.state, reason != .incident,
              let pipeline = source, pipeline.projectId == detail.task.projectId,
              pipeline.stages.first(where: { $0.id == detail.task.stageId })?.kind == .agent else { return nil }
        let question = reason == .question ? detail.humanRequests.last : nil
        if reason == .question && question == nil { return nil }
        guard question == nil || question?.taskId == detail.task.id else { return nil }
        card = detail.task; request = question
    }
    public func command(text: String, current: HumanAnswerContext?) -> Command? {
        guard self == current, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains("\0") else { return nil }
        return .answerHuman(taskId: card.id, text: text, requestId: request?.requestId)
    }
}

@MainActor @Observable public final class HumanAnswerStore {
    public struct Draft: Codable, Equatable, Sendable {
        public let context: HumanAnswerContext
        public var text: String
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
        catch { storageError = "Не удалось прочитать черновики ответов. \(error.localizedDescription)" }
    }
    public func currentContext(for id: TaskID) -> HumanAnswerContext? {
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
        if let saved = record(for: id) {
            // After a confirmed answer a new question starts empty. Old text
            // remains available in the durable feed, never sent again by default.
            if receipt(for: id)?.phase != .applied || currentContext(for: id) == saved.context { return saved }
        }
        return currentContext(for: id).map { Draft(context: $0, text: "", submittedBy: nil) }
    }
    public func isStale(_ id: TaskID) -> Bool {
        guard let draft = draft(for: id) else { return false }
        return draft.context != currentContext(for: id)
    }
    public func canSubmit(_ id: TaskID) -> Bool {
        guard storageError == nil, session.can(.answerHuman), session.detailReadState == .loaded,
              session.pending(in: .task(id)) == nil, let draft = draft(for: id),
              receipt(for: id)?.phase != .applied || draft.submittedBy == nil else { return false }
        return draft.context.command(text: draft.text, current: currentContext(for: id)) != nil
    }
    public func prepareNotificationReply(_ text: String, for id: TaskID, requestID: HumanRequestID) -> String? {
        guard storageError == nil else { return storageError }
        guard session.detailReadState == .loaded, let current = currentContext(for: id),
              current.request?.requestId == requestID else { return "Вопрос изменился или больше недоступен. Ответ не отправлен." }
        guard receipt(for: id)?.isPending != true, session.pending(in: .task(id)) == nil else {
            return "Для задачи уже ожидается подтверждение команды. Ответ не отправлен."
        }
        if let draft = draft(for: id), !draft.text.isEmpty, draft.text != text {
            return "В задаче сохранён другой черновик. Ответ из уведомления не заменил его."
        }
        guard current.command(text: text, current: current) != nil else { return "Напишите непустой ответ без служебных символов." }
        setText(text, for: id)
        return storageError
    }
    public func setText(_ text: String, for id: TaskID) {
        guard storageError == nil, receipt(for: id)?.isPending != true, var draft = draft(for: id) else { return }
        draft.text = text; draft.submittedBy = nil; save(draft)
    }
    /// An explicit UI action is required before carrying the old text to a new target.
    public func useTextForCurrentContext(_ id: TaskID) {
        guard storageError == nil, receipt(for: id)?.isPending != true,
              session.detailReadState == .loaded, let current = currentContext(for: id) else { return }
        save(.init(context: current, text: draft(for: id)?.text ?? "", submittedBy: nil))
    }
    private func save(_ draft: Draft) {
        do {
            let next = records.filter { $0.context.card.id != draft.context.card.id } + [draft]
            storage.set(try JSONEncoder().encode(next), forKey: key); records = next
        } catch { storageError = "Не удалось сохранить ответ. \(error.localizedDescription)" }
    }
    @discardableResult public func submit(_ id: TaskID) async -> Bool {
        guard canSubmit(id), var draft = draft(for: id),
              let command = draft.context.command(text: draft.text, current: currentContext(for: id)) else { return false }
        let envelope = CommandEnvelope(command: command)
        draft.submittedBy = envelope.commandId; save(draft)
        guard storageError == nil else { return false }
        let sent = await session.send(envelope, editor: true)
        if case .rejected(let failure) = receipt(for: id)?.phase,
           failure.code == CommandError.invalidStateCode, session.selectedID == id {
            await session.retryDetail()
        }
        return sent
    }
}
