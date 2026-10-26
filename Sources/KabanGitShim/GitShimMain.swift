import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KabanKit
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// A filter and a useful refusal, not a filesystem security boundary (BE-28).
@main
struct GitShimMain {
    private struct Check: Encodable { var argv: [String]; var cwd: String }
    private struct Decision: Decodable { var allow: Bool }

    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard let raw = env["KABAN_GIT_CHECK_URL"], let url = URL(string: raw),
                  url.scheme == "http", url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port),
                  url.path == "/git/check", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  let token = env["KABAN_RUN_TOKEN"], !token.isEmpty,
                  let git = env["KABAN_GIT_BIN"], git.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: git),
                  URL(fileURLWithPath: git).resolvingSymlinksInPath() != URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            else { deny() }
            let arguments = Array(CommandLine.arguments.dropFirst())
            var request = URLRequest(url: url, timeoutInterval: 2)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(Check(argv: arguments, cwd: FileManager.default.currentDirectoryPath))
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 2
            config.timeoutIntervalForResource = 2
            config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 65_536, try JSONDecoder().decode(Decision.self, from: data).allow else { deny() }
            // Replace this process: cwd, stdin/stdout/stderr, signals and exit status belong to real git.
            let strings = ([git] + arguments).map { strdup($0) }
            defer { strings.forEach { free($0) } }
            var pointers = strings + [nil]
            _ = pointers.withUnsafeMutableBufferPointer { execv(git, $0.baseAddress!) }
            deny()
        } catch { deny() }
    }

    private static func deny() -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((GitCheck.deniedMessage + "\n").utf8))
        exit(1)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
