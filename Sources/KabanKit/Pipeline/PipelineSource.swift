import Foundation
import KabanProtocol

/// Immutable snapshot of the project's root .kaban directory. Git tracking is irrelevant.
/// commit/referencedSkills remain decodable for existing run snapshots.
public struct PipelineSource: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var mode: String
        public var data: Data
        public init(mode: String = "100644", data: Data) { self.mode = mode; self.data = data }
    }
    public let commit: String
    public var files: [String: File]
    /// Legacy assets retained for decoding old runs; new sources use only root .kaban/.
    public var referencedSkills: [String: File]
    public init(commit: String, files: [String: File], referencedSkills: [String: File] = [:]) {
        self.commit = commit; self.files = files; self.referencedSkills = referencedSkills
    }
    public var yaml: String? { files[".kaban/pipeline.yaml"].flatMap { String(data: $0.data, encoding: .utf8) } }
    /// Hash the full asset snapshot, including executable bits and binary data. Unrelated commits
    /// do not change this identity; editing only a skill does. The wire draft hashes YAML separately.
    public func versionHash() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return PipelineContentHash.sha256(String(decoding: try encoder.encode(["files": files, "skills": referencedSkills]), as: UTF8.self))
    }
}

public extension LocalGitRepository {
    static var maxConfigurationBytes: Int { 16 * 1024 * 1024 }
    static var maxConfigurationFiles: Int { 1024 }

    /// Registration, recheck, observer and editor all read the same working directory.
    func pipelineSource() throws -> PipelineSource { try resolvePipelineSkills(workingPipelineSource()) }

    func resolvePipelineSkills(_ source: PipelineSource) throws -> PipelineSource {
        guard let yaml = source.yaml, yaml.utf8.count <= DaemonWire.maxPipelineBytes,
              let config = PipelineValidator.validate(yaml: yaml).config else { return source }
        for name in Set(config.stages.compactMap { $0.agent?.skill }) {
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first == ".kaban", components.count >= 2,
                  !name.contains("\0"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw Self.error("pipeline_invalid", "Скилл должен ссылаться на файл внутри корневой .kaban/.", ["path": name])
            }
        }
        return source
    }
}
