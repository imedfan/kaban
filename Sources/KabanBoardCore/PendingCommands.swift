import Foundation
import KabanProtocol

/// Команда ушла демону, карточка ждёт журнальное событие (§5, план фронта §2).
public struct PendingMark: Equatable, Sendable {
    public var commandId: CommandID
    public var taskId: TaskID
    public var sentAt: Date

    public init(commandId: CommandID, taskId: TaskID, sentAt: Date) {
        self.commandId = commandId
        self.taskId = taskId
        self.sentAt = sentAt
    }
}

/// «Отправлено» по `commandId`. Снимается `taskUpdated` с тем же id или ошибкой ответа.
public struct PendingCommands: Equatable, Sendable {
    public private(set) var marks: [CommandID: PendingMark]

    public init(marks: [CommandID: PendingMark] = [:]) {
        self.marks = marks
    }

    public func isSent(_ taskId: TaskID) -> Bool {
        marks.values.contains { $0.taskId == taskId }
    }

    public func mark(for taskId: TaskID) -> PendingMark? {
        marks.values.first { $0.taskId == taskId }
    }

    public mutating func markSent(commandId: CommandID, taskId: TaskID, at sentAt: Date) {
        marks[commandId] = PendingMark(commandId: commandId, taskId: taskId, sentAt: sentAt)
    }

    public mutating func clear(commandId: CommandID) {
        marks.removeValue(forKey: commandId)
    }

    public mutating func clear(taskId: TaskID) {
        marks = marks.filter { $0.value.taskId != taskId }
    }
}
