import Foundation

/// nil content means the file is absent, never an empty file. Hashes identify the
/// full committed asset snapshot; content is exact UTF-8 including CRLF/comments.
public struct PipelineSourceContent: Codable, Hashable, Sendable {
    public var projectId: ProjectID
    public var path: String
    public var baseVersionHash: String?
    public var baseSourceHash: String
    public var committedContent: String?
    public var workingContent: String?
    public var worktreeSourceHash: String
    public init(projectId: ProjectID, path: String, baseVersionHash: String?, baseSourceHash: String,
                committedContent: String?, workingContent: String?, worktreeSourceHash: String) {
        self.projectId = projectId; self.path = path; self.baseVersionHash = baseVersionHash
        self.baseSourceHash = baseSourceHash; self.committedContent = committedContent
        self.workingContent = workingContent; self.worktreeSourceHash = worktreeSourceHash
    }
    public var hasWorkingChanges: Bool {
        workingContent.map { Data($0.utf8) } != committedContent.map { Data($0.utf8) } || worktreeSourceHash != baseSourceHash
    }
}
