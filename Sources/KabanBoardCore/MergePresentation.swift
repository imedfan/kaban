import Foundation
import KabanProtocol

/// Presentation of source facts. It never advances a task or resolves a merge itself.
public enum MergePresentation {
    public static func queue(project: ProjectID, tasks: [TaskCard], pipeline: PipelineSummary?) -> [TaskCard] {
        let stages = Set(pipeline?.stages.filter { $0.kind == .merge }.map(\.id) ?? [])
        return tasks.filter {
            $0.projectId == project && stages.contains($0.stageId) && [.queued, .gating, .blocked].contains($0.state.status)
        }.sorted(by: precedes)
    }
    public static func precedes(_ a: TaskCard, _ b: TaskCard) -> Bool {
        switch (a.mergeQueueSequence, b.mergeQueueSequence) {
        case (.some(let aSeq), .some(let bSeq)) where aSeq != bSeq: return aSeq < bSeq
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.id.rawValue < b.id.rawValue
        }
    }
    public static func position(_ id: TaskID, queue: [TaskCard]) -> Int? {
        let sequences = queue.compactMap(\.mergeQueueSequence)
        guard sequences.count == queue.count, sequences.allSatisfy({ $0 > 0 }), Set(sequences).count == sequences.count,
              let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }
    public static func result(_ detail: TaskDetail) -> LocalMergeResult? {
        guard detail.task.state == .done else { return nil }
        return detail.artifacts.reversed().first { $0.taskId == detail.task.id && $0.kind == "merge_result" }.flatMap { artifact in
            guard artifact.text.utf8.count <= TaskDetailPresentation.largeTextBytes,
                  let result = try? KabanCoding.makeDecoder().decode(LocalMergeResult.self, from: Data(artifact.text.utf8)),
                  validSHA(result.commit), validSHA(result.baseCommit), result.ref.hasPrefix("refs/heads/"),
                  result.ref.count > "refs/heads/".count, !result.ref.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
            return result
        }
    }
    public static func conflict(_ artifact: TaskArtifact) -> MergeConflictMaterial? {
        guard artifact.kind == "merge_conflict", artifact.text.utf8.count <= TaskDetailPresentation.largeTextBytes else { return nil }
        return try? KabanCoding.makeDecoder().decode(MergeConflictMaterial.self, from: Data(artifact.text.utf8))
    }
    private static func validSHA(_ text: String) -> Bool {
        [40, 64].contains(text.count) && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
