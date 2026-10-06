import Foundation

/// Durable outcome of one restore intent. An accepted wire receipt alone is
/// pending; success/failure comes from the committed external effect receipt.
public struct WIPRestoreOperation: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, succeeded, failed, superseded }
    public var commandId: CommandID
    public var runId: RunID
    public var wipRef: String
    public var status: Status
    public var completedSeq: Seq?
    public var message: String?
    public init(commandId: CommandID, runId: RunID, wipRef: String, status: Status,
                completedSeq: Seq? = nil, message: String? = nil) {
        self.commandId = commandId; self.runId = runId; self.wipRef = wipRef
        self.status = status; self.completedSeq = completedSeq; self.message = message
    }
}
