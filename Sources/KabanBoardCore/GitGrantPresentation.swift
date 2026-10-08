import Foundation
import KabanProtocol

public struct GitGrantPresentation: Sendable {
    public enum State: String, Sendable { case created, delivered, consumed, revoked, expired, inconsistent }
    public struct Step: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let at: Date?
    }
    public let state: State
    public let steps: [Step]
    public let notice: String?

    public init(_ grant: GitGrantSnapshot, detail: TaskDetail) {
        let terminalCount = [grant.consumption != nil, grant.revocation != nil, grant.expiry != nil].filter { $0 }.count
        if terminalCount > 1 { state = .inconsistent }
        else if grant.consumption != nil { state = .consumed }
        else if grant.revocation != nil { state = .revoked }
        else if grant.expiry != nil { state = .expired }
        else if grant.delivery != nil { state = .delivered }
        else { state = .created }
        func run(_ id: RunID) -> String {
            detail.runs.first { $0.id == id }.map { "запуск #\($0.number)" } ?? id.rawValue
        }
        var values = [Step(id: "created", title: "Разрешено один раз", at: grant.createdAt)]
        if let delivery = grant.delivery {
            values.append(.init(id: "delivered", title: "Агент узнал · " + (delivery.via == .mcpResponse ? "ответ MCP" : "следующий промпт") + " · " + run(delivery.runId), at: grant.deliveredAt))
        }
        if let consumption = grant.consumption {
            values.append(.init(id: "consumed", title: "Использовано · " + run(consumption.runId), at: grant.consumedAt))
        }
        if grant.revocation != nil { values.append(.init(id: "revoked", title: "Отозвано", at: grant.revokedAt)) }
        if let expiry = grant.expiry {
            values.append(.init(id: "expired", title: "Истекло · " + (expiry.reason == .taskDone ? "задача завершена" : "задача отменена"), at: grant.expiredAt))
        }
        steps = values
        switch state {
        case .created:
            notice = detail.task.state == .running && detail.task.stageId == grant.stageId
                ? "Агент узнает при следующем вызове инструмента доски. Разрешение ещё не использовано."
                : "Разрешение доступно следующему запуску стадии \(grant.stageId.rawValue). Агент узнает при вызове инструмента доски."
        case .delivered: notice = "Доставлено агенту. Разрешение используется только при проверке этой команды git."
        case .inconsistent: notice = "Служба передала несколько конечных состояний. История показана без исправления исходных данных."
        case .consumed, .revoked, .expired: notice = nil
        }
    }
}
