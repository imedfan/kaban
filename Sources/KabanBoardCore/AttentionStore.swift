import Foundation
import Observation
import KabanProtocol

public enum AttentionTarget: Codable, Equatable, Sendable {
    case task(projectID: ProjectID, taskID: TaskID, requestID: HumanRequestID?)
    case incident(projectID: ProjectID, taskID: TaskID, incidentID: IncidentID)
    case board
}

public struct AttentionNotice: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let target: AttentionTarget
    public let timeSensitive: Bool
    public var canReply: Bool {
        if case .task(_, _, .some) = target { return true }
        return false
    }
}

@MainActor @Observable public final class AttentionStore {
    private struct Saved: Codable {
        var enabled = true
        var seq: Seq = 0
    }
    private struct Question {
        let request: HumanRequest
        let seq: Seq
        let at: Date
    }
    private let storage: any KeyValueStoring
    private let key: String
    private var saved = Saved()
    private var previous: [TaskID: TaskCard] = [:]
    private var flags: Set<String> = []
    private var questions: [TaskID: Question] = [:]
    public private(set) var error: String?
    public var enabled: Bool { saved.enabled }
    public init(storage: any KeyValueStoring, key: String) {
        self.storage = storage; self.key = key
        do { saved = try storage.data(forKey: key).map { try KabanCoding.makeDecoder().decode(Saved.self, from: $0) } ?? Saved() }
        catch { self.error = "Не удалось прочитать настройки уведомлений. Задачи продолжают работать." }
    }
    public func setEnabled(_ value: Bool) { guard error == nil else { return }; saved.enabled = value; persist() }
    public func receive(_ update: BoardSessionUpdate, board: BoardProjection, now: Date) -> [AttentionNotice] {
        guard error == nil else { return [] }
        var notices: [AttentionNotice] = []
        switch update {
        case .replacement:
            saved.seq = max(saved.seq, board.stateSeq)
            previous = board.tasks; flags = Set(board.ephemeral.schedulerFlags.compactMap(Self.flagKey)); questions = [:]
        case .journal(let event):
            guard event.seq > saved.seq else { return [] }
            saved.seq = event.seq
            switch event.event {
            case .humanRequested(let request):
                questions[request.taskId] = .init(request: request, seq: event.seq, at: event.at)
                if let card = board.tasks[request.taskId], card.state == .waitingHuman(.question) {
                    notices += takeQuestion(card, board: board, now: now)
                }
            case .humanAnswered(let answer): questions[answer.taskId] = nil
            case .taskCreated(let card), .taskUpdated(let card), .taskEdited(let card):
                if card.state == .waitingHuman(.question) { notices += takeQuestion(card, board: board, now: now) }
                else {
                    questions[card.id] = nil
                    if case .waitingHuman(let reason) = card.state, reason != .incident,
                       previous[card.id]?.state != card.state || previous[card.id]?.stageId != card.stageId,
                       isRecent(event.at, now: now) {
                        let project = board.projects[card.projectId]?.name ?? card.projectId.rawValue
                        notices.append(.init(id: "waiting.\(event.seq)", title: reason == .review ? "Результат ждёт ревью" : "Задача ждёт человека",
                                             body: project + " · " + card.title, target: .task(projectID: card.projectId, taskID: card.id, requestID: nil), timeSensitive: false))
                    }
                }
                previous[card.id] = card
            case .incidentOpened(let incident):
                if isRecent(event.at, now: now) {
                    notices.append(.init(id: "incident." + incident.id.rawValue, title: "Инцидент Kaban",
                                         body: (board.projects[incident.projectId]?.name ?? incident.projectId.rawValue) + " · " + incident.kind.rawValue,
                                         target: .incident(projectID: incident.projectId, taskID: incident.taskId, incidentID: incident.id), timeSensitive: true))
                }
            case .projectRemoved(let project):
                previous = previous.filter { $0.value.projectId != project }
                questions = questions.filter { previous[$0.key] != nil }
            default: break
            }
            notices += observeFlags(board.ephemeral.schedulerFlags, at: event.at, identity: "journal.\(event.seq)", now: now)
        case .ephemeral(let event):
            if case .schedulerFlagsChanged = event.event {
                notices += observeFlags(board.ephemeral.schedulerFlags, at: event.at,
                                        identity: "ephemeral.\(event.cursor.sessionId.uuidString).\(event.cursor.offset)", now: now)
            }
        }
        persist()
        return saved.enabled && error == nil ? notices : []
    }
    private func takeQuestion(_ card: TaskCard, board: BoardProjection, now: Date) -> [AttentionNotice] {
        guard let question = questions.removeValue(forKey: card.id), isRecent(question.at, now: now) else { return [] }
        return [.init(id: "question." + question.request.requestId.rawValue, title: "Вопрос по задаче «\(card.title)»",
                      body: (board.projects[card.projectId]?.name ?? card.projectId.rawValue) + " · " + question.request.question,
                      target: .task(projectID: card.projectId, taskID: card.id, requestID: question.request.requestId), timeSensitive: false)]
    }
    private func observeFlags(_ values: [SchedulerFlag], at: Date, identity: String, now: Date) -> [AttentionNotice] {
        let next = Set(values.compactMap(Self.flagKey)); defer { flags = next }
        guard isRecent(at, now: now) else { return [] }
        return values.compactMap { value in
            guard let key = Self.flagKey(value), !flags.contains(key) else { return nil }
            let title: String, body: String
            switch value {
            case .runnerUnavailable: title = "Cursor недоступен"; body = "Откройте Kaban и проверьте состояние Cursor."
            case .rateLimited(let until, _): title = "Лимит Cursor"; body = "Возобновление: " + until.formatted(date: .abbreviated, time: .shortened)
            default: return nil
            }
            return .init(id: identity + "." + key, title: title, body: body, target: .board, timeSensitive: false)
        }
    }
    private static func flagKey(_ flag: SchedulerFlag) -> String? {
        switch flag { case .runnerUnavailable: "runner"; case .rateLimited: "rate-limit"; default: nil }
    }
    private func isRecent(_ date: Date, now: Date) -> Bool { (0...600).contains(now.timeIntervalSince(date)) }
    private func persist() {
        do { storage.set(try KabanCoding.makeEncoder().encode(saved), forKey: key) }
        catch { self.error = "Не удалось сохранить журнал уведомлений. Задачи продолжают работать." }
    }
}
