import Foundation
import KabanProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum TaskFileAccess {
    public struct File: Sendable { public let url: URL; public let size: Int64 }
    public static func validate(clonePath: String?, relativePath: String) throws -> File {
        guard let clonePath, clonePath.hasPrefix("/"), !clonePath.contains("\0") else {
            throw CommandError(code: "clone_unavailable", message: "Клон отсутствует. Обновите детали задачи.")
        }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.contains("\0"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CommandError(code: "invalid_file_path", message: "Путь файла выходит за пределы клона или некорректен.")
        }
        let root = open(clonePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw unavailable() }
        var directory = root
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw unavailable() }
            close(directory); directory = next
        }
        let descriptor = openat(directory, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw unavailable() }
        return .init(url: URL(fileURLWithPath: clonePath).appendingPathComponent(relativePath), size: Int64(metadata.st_size))
    }
    private static func unavailable() -> CommandError {
        .init(code: "file_unavailable", message: "Файл недоступен, удалён, является ссылкой или выходит за пределы клона. Проверьте разрешения и обновите детали.")
    }
}
