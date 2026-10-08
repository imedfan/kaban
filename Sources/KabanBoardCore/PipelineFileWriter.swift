import Foundation
import KabanProtocol
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// File coordination protects cooperating native editors. Recheck exact bytes just
/// before atomic replacement; the daemon checks them again before Git preparation.
/// Never rolls back a refusal: late external edits always retain ownership.
public enum PipelineFileWriter {
    public static func write(_ content: String, source: PipelineSourceContent) throws {
        guard content.utf8.count <= DaemonWire.maxPipelineBytes, source.path.hasSuffix("/.kaban/pipeline.yaml") else { throw conflict() }
        let url = URL(fileURLWithPath: source.path)
        #if os(macOS)
        var coordinatorError: NSError?, writeError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { _ in
            do { try replace(content, source: source) } catch { writeError = error }
        }
        if let writeError { throw writeError }; if let coordinatorError { throw coordinatorError }
        #else
        try replace(content, source: source)
        #endif
    }
    private static func replace(_ content: String, source: PipelineSourceContent) throws {
        let url = URL(fileURLWithPath: source.path), directoryURL = url.deletingLastPathComponent()
        let root = directoryURL.deletingLastPathComponent()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw conflict() }; defer { close(rootFD) }
        if mkdirat(rootFD, ".kaban", 0o755) != 0 && errno != EEXIST { throw conflict() }
        let directory = openat(rootFD, ".kaban", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw conflict() }; defer { close(directory) }
        func current() throws -> Data? {
            let file = openat(directory, "pipeline.yaml", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if file < 0 && errno == ENOENT { return nil }; guard file >= 0 else { throw conflict() }; defer { close(file) }
            var info = stat(); guard fstat(file, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= DaemonWire.maxPipelineBytes else { throw conflict() }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
            return try handle.readToEnd()
        }
        let expected = source.workingContent.map { Data($0.utf8) }
        guard try current() == expected else { throw conflict() }
        let temporary = ".editor-" + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw conflict() }; defer { close(file); unlinkat(directory, temporary, 0) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        try handle.write(contentsOf: Data(content.utf8)); try handle.synchronize()
        guard try current() == expected else { throw conflict() }
        if expected == nil {
            guard linkat(directory, temporary, directory, "pipeline.yaml", 0) == 0 else { throw conflict() }
        } else {
            // Preserve the existing executable bit, never follow a symlink.
            var info = stat(); guard fstatat(directory, "pipeline.yaml", &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), fchmod(file, info.st_mode & 0o777) == 0,
                renameat(directory, temporary, directory, "pipeline.yaml") == 0 else { throw conflict() }
        }
    }
    private static func conflict() -> CommandError {
        .init(code: "pipeline_worktree_conflict", message: "pipeline.yaml изменился или недоступен. Ваш ввод сохранён. Перечитайте файл перед применением.")
    }
}
