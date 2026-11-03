import Foundation
import KabanProtocol
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public extension LocalGitRepository {
    func workingPipelineFile() throws -> PipelineSource.File? { try configurationFile(".kaban/pipeline.yaml") }
    // Legacy fields remain decodable for outstanding durable operations.
    struct PipelineCommit: Codable, Sendable {
        public let base: String
        public let commit: String
        public let source: PipelineSource
        public let previousIndex: Data
        public let blobs: [String: String]
        public var previousYAML: PipelineSource.File?
    }

    /// Descriptor-relative enumeration includes ignored and untracked files. Never follow links.
    func workingPipelineSource() throws -> PipelineSource {
        guard let parent = try configurationParent(".kaban/pipeline.yaml", create: false) else {
            return .init(commit: "", files: [:])
        }
        defer { close(parent) }
        var files: [String: PipelineSource.File] = [:], total = 0, entries = 0
        func walk(_ directory: Int32, prefix: String, depth: Int) throws {
            guard depth <= 32, let stream = fdopendir(dup(directory)) else {
                throw Self.error("pipeline_invalid", "Не удалось прочитать .kaban/ или превышена глубина каталогов.")
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Self.error("pipeline_invalid", "Не удалось прочитать .kaban/.") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(validatingCString: $0) }
                }
                guard let name else { throw Self.error("pipeline_invalid", "Пути .kaban/ должны быть UTF-8.") }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= Self.maxConfigurationFiles else { throw Self.error("pipeline_invalid", "В .kaban/ слишком много файлов.") }
                let path = prefix + "/" + name
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.error("pipeline_worktree_conflict", "Файлы .kaban/ изменились при чтении.")
                }
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Self.error("pipeline_invalid", ".kaban/ содержит ссылку или недоступный каталог.") }
                    defer { close(child) }
                    try walk(child, prefix: path, depth: depth + 1)
                } else {
                    guard let file = try readConfigurationFile(directory: directory, name: name) else {
                        throw Self.error("pipeline_worktree_conflict", "Файлы .kaban/ изменились при чтении.")
                    }
                    total += file.data.count
                    guard total <= Self.maxConfigurationBytes else { throw Self.error("pipeline_invalid", "Содержимое .kaban/ превышает лимит размера.") }
                    files[path] = file
                }
            }
        }
        try walk(parent, prefix: ".kaban", depth: 0)
        return .init(commit: "", files: files)
    }

    /// Prepare the exact next snapshot. The caller binds the old source and persists intent first.
    func preparePipeline(content: String, source: PipelineSource, identity: GitIdentity, commandId: CommandID,
                         requiresExactWorkingContent: Bool = false) throws -> PipelineCommit {
        guard content.utf8.count <= DaemonWire.maxPipelineBytes else { throw Self.error("invalid_request", "Черновик пайплайна превышает лимит размера.") }
        let working = try pipelineSource(), previous = working.files[".kaban/pipeline.yaml"]
        guard try working.versionHash() == source.versionHash() else {
            throw Self.error(CommandError.stalePipelineDraftCode, "Содержимое .kaban/ изменилось при подготовке новой версии.")
        }
        let requested = Data(content.utf8)
        guard !requiresExactWorkingContent || previous?.data == requested else {
            throw Self.error("pipeline_worktree_conflict", "Рабочий файл изменился после записи черновика. Перечитайте файл.")
        }
        guard previous == nil || previous?.data == requested || previous == source.files[".kaban/pipeline.yaml"] else {
            throw Self.error("pipeline_worktree_conflict", "pipeline.yaml изменён отдельно от черновика; обновите черновик перед применением.")
        }
        var candidate = working
        candidate.files[".kaban/pipeline.yaml"] = .init(mode: previous?.mode ?? "100644", data: requested)
        return .init(base: "", commit: "", source: try resolvePipelineSkills(candidate), previousIndex: Data(), blobs: [:], previousYAML: previous)
    }

    /// No Git effect. Replaying a persisted plan preserves later external file edits.
    func finishPipeline(_ plan: PipelineCommit) throws { try installPipelineYAML(plan) }

    private func configurationParent(_ name: String, create: Bool) throws -> Int32? {
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.first == ".kaban", components.count >= 2, !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." || $0.contains("\0") }) else {
            throw Self.error("pipeline_invalid", "Некорректный путь .kaban/.")
        }
        var directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.error("project_missing", "Папка проекта недоступна.") }
        for component in components.dropLast() {
            if create && mkdirat(directory, component, 0o755) != 0 && errno != EEXIST {
                close(directory); throw Self.error("pipeline_worktree_conflict", "Не удалось создать папку .kaban/.")
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(directory)
            if next < 0 {
                if !create && code == ENOENT { return nil }
                throw Self.error("pipeline_worktree_conflict", ".kaban/ содержит ссылку или конфликтующий файл.")
            }
            directory = next
        }
        return directory
    }
    private func configurationFile(_ name: String) throws -> PipelineSource.File? {
        guard let directory = try configurationParent(name, create: false) else { return nil }
        defer { close(directory) }
        return try readConfigurationFile(directory: directory, name: String(name.split(separator: "/").last!))
    }
    private func readConfigurationFile(directory: Int32, name: String) throws -> PipelineSource.File? {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw Self.error("pipeline_worktree_conflict", ".kaban/ содержит ссылку или недоступный файл.") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= Self.maxConfigurationBytes else {
            throw Self.error("pipeline_worktree_conflict", ".kaban/ содержит специальный или слишком большой файл.")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, Self.maxConfigurationBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > Self.maxConfigurationBytes { break }
        }
        guard data.count <= Self.maxConfigurationBytes, data.count == info.st_size else {
            throw Self.error("pipeline_worktree_conflict", "Файл .kaban/ изменился при чтении.")
        }
        var after = stat()
        guard fstat(file, &after) == 0, after.st_size == info.st_size else { throw Self.error("pipeline_worktree_conflict", "Файл .kaban/ изменился при чтении.") }
        #if os(macOS)
        let beforeTime = info.st_mtimespec, afterTime = after.st_mtimespec
        #else
        let beforeTime = info.st_mtim, afterTime = after.st_mtim
        #endif
        guard beforeTime.tv_sec == afterTime.tv_sec, beforeTime.tv_nsec == afterTime.tv_nsec else {
            throw Self.error("pipeline_worktree_conflict", "Файл .kaban/ изменился при чтении.")
        }
        return .init(mode: info.st_mode & mode_t(S_IXUSR) == 0 ? "100644" : "100755", data: data)
    }
    private func installPipelineYAML(_ plan: PipelineCommit) throws {
        guard let desired = plan.source.files[".kaban/pipeline.yaml"],
              let directory = try configurationParent(".kaban/pipeline.yaml", create: true) else { return }
        defer { close(directory) }
        let current = try readConfigurationFile(directory: directory, name: "pipeline.yaml")
        if current == desired { return }
        // A new intent can replace only the bytes observed during preparation. Legacy intents
        // preserve every existing file, and recovery never overwrites a subsequent editor save.
        guard current == nil || (plan.commit.isEmpty && current == plan.previousYAML) else { return }
        let temporary = ".kaban-pipeline-" + UUID().uuidString.lowercased()
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, desired.mode == "100755" ? 0o755 : 0o644)
        guard file >= 0 else { throw Self.error("pipeline_worktree_conflict", "Не удалось записать pipeline.yaml.") }
        defer { close(file); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        try handle.write(contentsOf: desired.data); try handle.synchronize()
        guard try readConfigurationFile(directory: directory, name: "pipeline.yaml") == current else { return }
        if current == nil {
            if linkat(directory, temporary, directory, "pipeline.yaml", 0) != 0 && errno != EEXIST {
                throw Self.error("pipeline_worktree_conflict", "Не удалось установить pipeline.yaml.")
            }
        } else if renameat(directory, temporary, directory, "pipeline.yaml") != 0 {
            throw Self.error("pipeline_worktree_conflict", "Не удалось установить pipeline.yaml.")
        }
    }
}
