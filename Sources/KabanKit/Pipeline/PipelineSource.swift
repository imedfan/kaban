import Foundation
import KabanProtocol

/// Exact committed configuration assets, independent of the user's checkout and mutable refs.
/// Keep the commit for files outside .kaban needed by a later execution workspace.
public struct PipelineSource: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var mode: String
        public var data: Data
        public init(mode: String = "100644", data: Data) { self.mode = mode; self.data = data }
    }
    public let commit: String
    public var files: [String: File]
    /// Skills referenced outside .kaban are still pinned to the same commit. They are read-only
    /// version assets; applying the pipeline never adds their working copies to its commit.
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

    /// Resolve main once: every blob is then addressed by immutable object id.
    func pipelineSource() throws -> PipelineSource {
        let commit = try mainCommit()
        let entries = try git(["ls-tree", "-rz", commit, "--", ".kaban"]).data.split(separator: 0)
        guard entries.count <= Self.maxConfigurationFiles else { throw Self.error("pipeline_invalid", "В .kaban/ слишком много файлов.") }
        var files: [String: PipelineSource.File] = [:], total = 0
        for entry in entries {
            guard let tab = entry.firstIndex(of: 9), let name = String(data: entry[entry.index(after: tab)...], encoding: .utf8) else {
                throw Self.error("pipeline_invalid", "Пути .kaban/ должны быть UTF-8.")
            }
            let header = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard header.count == 3, header[1] == "blob", ["100644", "100755"].contains(String(header[0])) else {
                throw Self.error("pipeline_invalid", ".kaban/ содержит ссылку или вложенный репозиторий.", ["path": name])
            }
            let data = try git(["cat-file", "blob", String(header[2])], maxBytes: Self.maxConfigurationBytes).data
            total += data.count
            guard total <= Self.maxConfigurationBytes else { throw Self.error("pipeline_invalid", "Содержимое .kaban/ превышает лимит размера.") }
            files[name] = .init(mode: String(header[0]), data: data)
        }
        return try resolvePipelineSkills(PipelineSource(commit: commit, files: files))
    }

    func resolvePipelineSkills(_ source: PipelineSource) throws -> PipelineSource {
        var source = source
        source.referencedSkills = [:]
        guard let yaml = source.yaml, yaml.utf8.count <= DaemonWire.maxPipelineBytes,
              let config = PipelineValidator.validate(yaml: yaml).config else { return source }
        var total = source.files.values.reduce(0) { $0 + $1.data.count }
        let skills = Set(config.stages.compactMap { $0.agent?.skill })
        for name in skills.sorted() where source.files[name] == nil {
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\0"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw Self.error("pipeline_invalid", "Скилл должен ссылаться на файл внутри репозитория.", ["path": name])
            }
            let entry = try git(["ls-tree", "-z", source.commit, "--", ":(literal)" + name]).data
            if entry.isEmpty { continue } // The existing validator permits absent/optional skills.
            guard let tab = entry.firstIndex(of: 9) else { throw Self.error("pipeline_invalid", "Не удалось прочитать скилл.") }
            let header = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard header.count == 3, header[1] == "blob", ["100644", "100755"].contains(String(header[0])) else {
                throw Self.error("pipeline_invalid", "Скилл не может быть ссылкой или каталогом.", ["path": name])
            }
            let data = try git(["cat-file", "blob", String(header[2])], maxBytes: Self.maxConfigurationBytes).data
            total += data.count
            guard total <= Self.maxConfigurationBytes, source.files.count + source.referencedSkills.count < Self.maxConfigurationFiles else {
                throw Self.error("pipeline_invalid", "Снимок пайплайна со скиллами превышает лимит размера.")
            }
            source.referencedSkills[name] = .init(mode: String(header[0]), data: data)
        }
        return source
    }
}
