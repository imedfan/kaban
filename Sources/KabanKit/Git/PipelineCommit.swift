import Foundation
import KabanProtocol
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public extension LocalGitRepository {
    func workingPipelineFile() throws -> PipelineSource.File? { try configurationFile(".kaban/pipeline.yaml") }
    struct PipelineCommit: Codable, Sendable {
        public let base: String
        public let commit: String
        public let source: PipelineSource
        public let previousIndex: Data
        public let blobs: [String: String]
    }

    /// Read only tracked and non-ignored untracked configuration paths. Descriptor-relative reads
    /// reject links, special files and paths outside .kaban; Git filters never see their contents.
    func workingPipelineSource() throws -> PipelineSource {
        let names = try git(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ".kaban"]).data.split(separator: 0)
        guard names.count <= Self.maxConfigurationFiles else { throw Self.error("pipeline_invalid", "В .kaban/ слишком много файлов.") }
        var files: [String: PipelineSource.File] = [:], total = 0
        for bytes in names {
            guard let name = String(data: bytes, encoding: .utf8) else { throw Self.error("pipeline_invalid", "Пути .kaban/ должны быть UTF-8.") }
            if files[name] == nil, let file = try configurationFile(name) {
                total += file.data.count
                guard total <= Self.maxConfigurationBytes else { throw Self.error("pipeline_invalid", "Содержимое .kaban/ превышает лимит размера.") }
                files[name] = file
            }
        }
        return .init(commit: try mainCommit(), files: files)
    }

    /// Prepare immutable objects, leaving all refs, working files and the user's index unchanged.
    /// Caller validates candidate YAML and persists this plan before publishing the commit.
    func preparePipeline(content: String, source: PipelineSource, identity: GitIdentity, commandId: CommandID,
                         requiresExactWorkingContent: Bool = false) throws -> PipelineCommit {
        guard try git(["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true).text == "refs/heads/main" else {
            throw Self.error("pipeline_checkout_required", "Для применения пайплайна откройте main.", ["baseBranch": "main"])
        }
        guard content.utf8.count <= DaemonWire.maxPipelineBytes else { throw Self.error("invalid_request", "Черновик пайплайна превышает лимит размера.") }
        let working = try workingPipelineSource(), previous = try workingPipelineFile()
        let requested = Data(content.utf8)
        guard !requiresExactWorkingContent || previous?.data == requested else {
            throw Self.error("pipeline_worktree_conflict", "Рабочий файл изменился после записи черновика. Перечитайте файл.")
        }
        guard previous == nil || previous?.data == requested || previous == source.files[".kaban/pipeline.yaml"] else {
            throw Self.error("pipeline_worktree_conflict", "pipeline.yaml изменён отдельно от черновика; обновите черновик перед применением.")
        }
        var candidate = working
        candidate.files[".kaban/pipeline.yaml"] = .init(mode: previous?.mode ?? source.files[".kaban/pipeline.yaml"]?.mode ?? "100644", data: requested)
        let previousIndex = try git(["ls-files", "--stage", "-z", "--", ".kaban"]).data
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let index = scratch.appendingPathComponent("index").path
        _ = try git(["read-tree", source.commit], index: index)
        let old = try git(["ls-files", "-z", "--", ".kaban"], index: index).data
        if !old.isEmpty { _ = try git(["update-index", "--force-remove", "-z", "--stdin"], index: index, input: old) }
        var blobs: [String: String] = [:]
        for name in candidate.files.keys.sorted() {
            let file = candidate.files[name]!
            blobs[name] = try git(["hash-object", "-w", "--no-filters", "--stdin"], input: file.data).text
        }
        _ = try git(["update-index", "-z", "--index-info"], index: index, input: indexRecords(files: candidate.files, blobs: blobs))
        let tree = try git(["write-tree"], index: index).text
        let originalTree = try git(["rev-parse", source.commit + "^{tree}"]).text
        let commit = tree == originalTree ? source.commit : try git(["commit-tree", tree, "-p", source.commit], identity: identity,
            input: Data("Update Kaban pipeline\n\nKaban-Command: \(commandId.uuidString.lowercased())\n".utf8)).text
        return .init(base: source.commit, commit: commit, source: try resolvePipelineSkills(.init(commit: commit, files: candidate.files)),
                     previousIndex: previousIndex, blobs: blobs)
    }

    /// Ref compare-and-swap and conditional repairs make the persisted plan replayable. Edits
    /// made after preparation/restart survive; a newer descendant main is never rewound.
    func finishPipeline(_ plan: PipelineCommit) throws {
        let current = try mainCommit()
        if current != plan.commit {
            if current == plan.base {
                guard try git(["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true).text == "refs/heads/main" else {
                    throw Self.error("pipeline_checkout_required", "Checkout изменился до применения пайплайна.")
                }
                let update = try git(["update-ref", "-m", "Kaban pipeline", "refs/heads/main", plan.commit, plan.base], allowedFailure: true)
                guard update.status == 0 else { throw Self.error("git_race", "main изменился; обновите черновик и повторите новой командой.") }
            } else {
                guard try git(["merge-base", "--is-ancestor", plan.commit, current], allowedFailure: true).status == 0 else {
                    throw Self.error("git_race", "main изменился; обновите черновик и повторите новой командой.")
                }
                return
            }
        }
        guard try git(["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true).text == "refs/heads/main" else { return }
        try installPipelineYAML(plan)
        try reconcilePipelineIndex(plan)
    }

    private func indexRecords(files: [String: PipelineSource.File], blobs: [String: String]) -> Data {
        Data(files.keys.sorted().map { "\(files[$0]!.mode) \(blobs[$0]!)\t\($0)\0" }.joined().utf8)
    }
    private func reconcilePipelineIndex(_ plan: PipelineCommit) throws {
        let indexPath = try git(["rev-parse", "--path-format=absolute", "--git-path", "index"]).text
        let lockPath = indexPath + ".lock"
        let lock = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Self.error("git_index_busy", "Индекс занят; применение будет продолжено при повторе.") }
        defer { close(lock); unlink(lockPath) }
        // Git writers respect index.lock. Work on a private copy so every unrelated entry survives.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("index").path
        let descriptor = open(indexPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try (handle.readToEnd() ?? Data()).write(to: URL(fileURLWithPath: copy)); try handle.close()
        } else if errno == ENOENT { _ = try git(["read-tree", "--empty"], index: copy) }
        else { throw Self.error("git_operation_failed", "Не удалось прочитать индекс.") }
        let entries = try git(["ls-files", "--stage", "-z", "--", ".kaban"], index: copy).data
        guard entries == plan.previousIndex else { return } // A later staged edit owns these entries.
        let old = try git(["ls-files", "-z", "--", ".kaban"], index: copy).data
        if !old.isEmpty { _ = try git(["update-index", "--force-remove", "-z", "--stdin"], index: copy, input: old) }
        _ = try git(["update-index", "-z", "--index-info"], index: copy, input: indexRecords(files: plan.source.files, blobs: plan.blobs))
        let handle = FileHandle(fileDescriptor: lock, closeOnDealloc: false)
        try handle.write(contentsOf: Data(contentsOf: URL(fileURLWithPath: copy))); try handle.synchronize()
        guard rename(lockPath, indexPath) == 0 else { throw Self.error("git_operation_failed", "Не удалось обновить индекс .kaban/.") }
    }

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
        // Existing files belong to the editor. Even a compare followed by rename would lose
        // a concurrent atomic editor save. Only create an absent file with an exclusive link.
        guard try readConfigurationFile(directory: directory, name: "pipeline.yaml") == nil else { return }
        let temporary = ".kaban-pipeline-" + UUID().uuidString.lowercased()
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, desired.mode == "100755" ? 0o755 : 0o644)
        guard file >= 0 else { throw Self.error("pipeline_worktree_conflict", "Не удалось записать pipeline.yaml.") }
        defer { close(file); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        try handle.write(contentsOf: desired.data); try handle.synchronize()
        if linkat(directory, temporary, directory, "pipeline.yaml", 0) != 0 && errno != EEXIST {
            throw Self.error("pipeline_worktree_conflict", "Не удалось установить pipeline.yaml.")
        }
    }
}
