import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loopback MCP endpoint for the five board tools. It listens only on 127.0.0.1.
public final class MCPBoardServer: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    private let store: KabanStore
    private let now: () -> Date
    private let lock = NSLock()
    private var listenFD: Int32
    private var stopped = false

    public init(store: KabanStore, now: @escaping () -> Date = Date.init) throws {
        self.store = store
        self.now = now
        let bound = try Self.bindLoopback()
        self.listenFD = bound.fd
        self.host = bound.host
        self.port = bound.port
        guard host == "127.0.0.1" else { throw BoardFailure.invalid("MCP слушает не loopback.") }
        Thread.detachNewThread { [self] in
            self.acceptLoop()
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    func roundTrip(token: String, method: String, params: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let fd = try Self.connectLoopback(port: port)
        defer { close(fd) }
        try Self.writeAll(fd, request)
        let data = try Self.readAll(fd, limit: 1_048_576)
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { throw BoardFailure.invalid("Нет HTTP-ответа.") }
        let payload = data[range.upperBound...]
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let stop = stopped
            let fd = listenFD
            lock.unlock()
            if stop || fd < 0 { return }
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            if client < 0 { return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        let data: Data
        do { data = try Self.readHeadersAndBody(client, limit: 65_536) } catch {
            Self.writeHTTP(client, status: "400 Bad Request", body: Self.errorBody(id: 0, message: "Плохой запрос."))
            return
        }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            Self.writeHTTP(client, status: "400 Bad Request", body: Self.errorBody(id: 0, message: "Плохой запрос."))
            return
        }
        let body = Data(data[headerEnd.upperBound...])
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let request = lines.first, request.hasPrefix("POST /mcp ") else {
            Self.writeHTTP(client, status: "404 Not Found", body: Self.errorBody(id: 0, message: "Только POST /mcp."))
            return
        }
        let token = Self.bearer(head)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let id = json?["id"] ?? 0
        let method = json?["method"] as? String ?? ""
        guard let token else {
            Self.writeHTTP(client, status: "401 Unauthorized", body: Self.errorBody(id: id, message: "Токен не подходит к этому запуску."))
            return
        }
        do {
            if method == "initialize" || method == "tools/list" {
                try store.requireBoardToken(token)
                let result: [String: Any] = method == "initialize"
                    ? ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "kaban", "version": "0.9"]]
                    : ["tools": Self.tools()]
                Self.writeHTTP(client, status: "200 OK", body: try Self.resultBody(id: id, result: result))
                return
            }
            guard method == "tools/call", let params = json?["params"] as? [String: Any], let name = params["name"] as? String else {
                throw BoardFailure.invalid("Нужен tools/call.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let response = try store.performBoardTool(token: token, name: name, arguments: arguments, at: now())
            var structured: [String: Any] = [
                "taskId": response.taskId, "projectId": response.projectId, "stageId": response.stageId,
                "runId": response.runId, "title": response.title, "state": response.state, "notices": response.notices,
            ]
            structured["body"] = response.body ?? NSNull()
            let result: [String: Any] = [
                "content": [["type": "text", "text": response.message]],
                "isError": false,
                "structuredContent": structured,
                "notices": response.notices,
            ]
            Self.writeHTTP(client, status: "200 OK", body: try Self.resultBody(id: id, result: result))
        } catch let failure as BoardFailure {
            switch failure {
            case .unauthorized(let message):
                Self.writeHTTP(client, status: "401 Unauthorized", body: Self.errorBody(id: id, message: message))
            case .rejected(let message), .invalid(let message):
                Self.writeHTTP(client, status: "200 OK", body: Self.errorBody(id: id, message: message))
            }
        } catch {
            Self.writeHTTP(client, status: "500 Internal Server Error", body: Self.errorBody(id: id, message: "Инструмент не выполнен."))
        }
    }

    private static func bearer(_ head: String) -> String? {
        for line in head.split(separator: "\r\n") {
            let text = String(line)
            if text.lowercased().hasPrefix("authorization:") {
                let value = text.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
                guard value.lowercased().hasPrefix("bearer ") else { return nil }
                let token = value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
                return token.isEmpty ? nil : token
            }
        }
        return nil
    }

    private static func tools() -> [[String: Any]] {
        ["get_task_context", "report_progress", "complete_stage", "return_to_stage", "request_human"].map {
            ["name": $0, "inputSchema": ["type": "object"]]
        }
    }

    private static func resultBody(id: Any, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorBody(id: Any, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]])) ?? Data("{}".utf8)
    }

    private static func writeHTTP(_ fd: Int32, status: String, body: Data) {
        let head = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        try? writeAll(fd, head + body)
    }

    private static func bindLoopback() throws -> (fd: Int32, host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BoardFailure.invalid("Сокет MCP не открылся.") }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw BoardFailure.invalid("MCP не слушает 127.0.0.1.")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0, actual.sin_addr.s_addr == inet_addr("127.0.0.1") else {
            close(fd)
            throw BoardFailure.invalid("MCP слушает не 127.0.0.1.")
        }
        return (fd, "127.0.0.1", UInt16(bigEndian: actual.sin_port))
    }

    private static func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BoardFailure.invalid("Клиент MCP не открылся.") }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw BoardFailure.invalid("Нет соединения с MCP.")
        }
        return fd
    }

    private static func readHeadersAndBody(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        while data.count < limit {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw BoardFailure.invalid("Обрыв чтения.") }
            data.append(buffer, count: count)
            if let range = data.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: data[..<range.lowerBound], encoding: .utf8),
               let length = contentLength(head), data.count >= range.upperBound + length {
                return Data(data.prefix(range.upperBound + length))
            }
        }
        throw BoardFailure.invalid("Неполное HTTP-сообщение.")
    }

    private static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        while data.count < limit {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw BoardFailure.invalid("Обрыв чтения.") }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                #if os(Linux)
                let count = send(fd, base.advanced(by: sent), data.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let count = write(fd, base.advanced(by: sent), data.count - sent)
                #endif
                if count < 0 { if errno == EINTR { continue }; throw BoardFailure.invalid("Обрыв записи.") }
                sent += count
            }
        }
    }

    private static func contentLength(_ head: String) -> Int? {
        for line in head.split(separator: "\r\n") {
            let text = String(line)
            if text.lowercased().hasPrefix("content-length:") {
                return Int(text.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
