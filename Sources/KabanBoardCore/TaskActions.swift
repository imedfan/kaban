import Foundation
import KabanProtocol

/// Editor data for the demo adapter. The wire contract currently has a single Markdown body.
public struct DemoTaskDraft: Codable, Equatable, Sendable {
    public var title: String
    public var description: String
    public var acceptanceCriteria: String
    public init(title: String = "", description: String = "", acceptanceCriteria: String = "") {
        self.title = title; self.description = description; self.acceptanceCriteria = acceptanceCriteria
    }
    public var canSubmit: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !title.contains("\0") }
    public var body: String { description + TaskMarkdown.acceptanceCriteriaSeparator + acceptanceCriteria }
    public init(title: String, body: String) {
        let separator = TaskMarkdown.acceptanceCriteriaSeparator
        if let range = body.range(of: separator, options: .backwards) {
            self.init(title: title, description: String(body[..<range.lowerBound]), acceptanceCriteria: String(body[range.upperBound...]))
        } else { self.init(title: title, description: body) }
    }
    public var hasAcceptanceCriteria: Bool { !acceptanceCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum TaskActions {
    public static func canEdit(_ card: TaskCard) -> Bool { [.queued, .waitingHuman, .paused].contains(card.state.status) }
    public static func canSetPriority(_ card: TaskCard) -> Bool { ![.done, .cancelled].contains(card.state.status) }
    public static func canCancel(_ card: TaskCard) -> Bool { card.state.status != .done && card.state.status != .cancelled }
    /// Advisory UI affordance from the existing pipeline/card contract. The command receiver revalidates.
    public static func moveDecision(card: TaskCard, target: StageSummary, pipeline: PipelineSummary) -> DropDecision {
        guard canCancel(card) else { return .forbidden(.forwardMove) }
        return DropRules.evaluate(card: card, target: target, in: pipeline)
    }
}

/// Correlates an in-flight creation without adding a placeholder card on command acknowledgement.
public struct TaskCreationPending: Equatable, Sendable {
    public private(set) var commandID: CommandID?
    public private(set) var projectID: ProjectID?
    public init() {}
    @discardableResult public mutating func begin(commandID: CommandID, projectID: ProjectID) -> Bool {
        guard self.commandID == nil else { return false }
        self.commandID = commandID; self.projectID = projectID
        return true
    }
    public mutating func finish(with event: EventEnvelope) -> TaskID? {
        guard event.commandId == commandID, commandID != nil,
              case .taskCreated(let card) = event.event, card.projectId == projectID else { return nil }
        commandID = nil; projectID = nil
        return card.id
    }
    public mutating func fail(_ commandID: CommandID) {
        guard self.commandID == commandID else { return }
        self.commandID = nil; self.projectID = nil
    }
}

/// Same-task refreshes can race too: identity alone does not protect a newer selection request.
public struct TaskDetailSelection: Equatable, Sendable {
    public private(set) var taskID: TaskID?
    private var generation = UUID()
    public init() {}
    public mutating func begin(_ taskID: TaskID?) -> UUID {
        self.taskID = taskID; generation = UUID(); return generation
    }
    public func accepts(_ generation: UUID, taskID: TaskID) -> Bool { self.generation == generation && self.taskID == taskID }
    public func accepts(_ generation: UUID, detail: TaskDetail, minimumSeq: Seq) -> Bool {
        accepts(generation, taskID: detail.task.id) && detail.seq >= minimumSeq
    }
}
