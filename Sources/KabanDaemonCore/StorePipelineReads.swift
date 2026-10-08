import Foundation
import KabanKit
import KabanProtocol

extension KabanStore {
    /// Query only: observe current Git outside SQLite; no refresh/journal/receipt.
    func readPipelineSource(_ envelope: CommandEnvelope, projectId: ProjectID) throws -> CommandReply {
        do {
            guard envelope.protocolVersion == KabanCoding.protocolVersion else {
                throw CommandError(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")
            }
            let record = try database.read { try Self.project(projectId, db: $0) }
            guard record.production != nil else {
                throw CommandError(code: CommandError.unsupportedCommandCode, message: "Исходный YAML доступен для локальных проектов.")
            }
            let repository = try LocalGitRepository(path: record.summary.path)
            guard repository.repositoryID == record.production?.repositoryID else {
                throw CommandError(code: "repository_changed", message: "По сохранённому пути находится другой репозиторий.")
            }
            let committed = try repository.pipelineSource(), working = try repository.workingPipelineSource()
            func text(_ file: PipelineSource.File?) throws -> String? {
                guard let file else { return nil }
                guard file.data.count <= DaemonWire.maxPipelineBytes, let value = String(data: file.data, encoding: .utf8) else {
                    throw CommandError(code: "pipeline_invalid", message: "pipeline.yaml должен быть UTF-8 размером не более 1 МиБ.")
                }
                return value
            }
            let valid = try database.read { try Self.sourceValidation(committed, projectId: projectId, db: $0).isValid }
            let hash = try committed.versionHash()
            let value = PipelineSourceContent(projectId: projectId, path: record.summary.path + "/.kaban/pipeline.yaml",
                baseVersionHash: valid ? hash : nil, baseSourceHash: hash,
                committedContent: try text(committed.files[".kaban/pipeline.yaml"]), workingContent: try text(repository.workingPipelineFile()),
                worktreeSourceHash: try working.versionHash())
            return .init(commandId: envelope.commandId, seq: nil, result: .pipelineSource(value))
        } catch let error as CommandError { return .init(commandId: envelope.commandId, seq: nil, result: .error(error)) }
        catch let error as StoreError { return Self.failure(error, commandId: envelope.commandId) }
    }
}
