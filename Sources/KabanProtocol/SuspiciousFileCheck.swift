import Foundation

/// The task's frozen file-check policy, rather than a frontend default or an edited project draft.
public struct SuspiciousFileCheck: Codable, Hashable, Sendable {
    public var maxFileBytes: Int64
    public var includesUncommitted: Bool
    public var baseCommit: String?
    public var bounceLimitTotal: Int?
    public var returnPipeline: PipelineSummary?
    public init(maxFileBytes: Int64, includesUncommitted: Bool, baseCommit: String?, bounceLimitTotal: Int? = nil,
                returnPipeline: PipelineSummary? = nil) {
        self.maxFileBytes = maxFileBytes; self.includesUncommitted = includesUncommitted; self.baseCommit = baseCommit
        self.bounceLimitTotal = bounceLimitTotal
        self.returnPipeline = returnPipeline
    }
}
