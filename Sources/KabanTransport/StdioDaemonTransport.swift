import Foundation
import KabanProtocol
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Explicit development transport: a child process, inherited private pipes and a chosen DB.
/// Blocking pipe IO is confined to a serial queue, with cancellation and a request deadline.
public final class StdioDaemonTransport: DaemonTransport, Sendable {
    private let worker: StdioWorker
    private let timeout: TimeInterval

    public init(executable: URL, database: String, additionalArguments: [String] = [], timeout: TimeInterval = 10) {
        worker = StdioWorker(executable: executable, database: database, additionalArguments: additionalArguments)
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 60) : 10
    }
    public func exchange(_ request: DaemonRequest) async throws -> DaemonResponse {
        try Task.checkCancellation()
        let payload = try DaemonWire.encode(request), completion = RPCCompletion()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                worker.queue.async { self.worker.exchange(payload, completion: completion) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak completion, weak self] in
                    if completion?.finish(.failure(DaemonTransportError.timedOut)) == true { self?.worker.stop() }
                }
            }
        } onCancel: {
            if completion.finish(.failure(CancellationError())) { self.worker.stop() }
        }
        do { return try DaemonWire.decode(DaemonResponse.self, from: data) }
        catch { throw DaemonTransportError.invalidReply }
    }
    public func close() async {
        worker.shutdown()
        await withCheckedContinuation { continuation in
            worker.queue.async { self.worker.close(); continuation.resume() }
        }
    }
    deinit { worker.shutdown() }
}

/// IO state belongs to queue; process cancellation and terminal shutdown use lock.
private final class StdioWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.kaban.stdio")
    private let executable: URL
    private let database: String
    private let additionalArguments: [String]
    private let lock = NSLock()
    private var closed = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    init(executable: URL, database: String, additionalArguments: [String]) { self.executable = executable; self.database = database; self.additionalArguments = additionalArguments }
    func exchange(_ data: Data, completion: RPCCompletion) {
        guard !completion.isFinished else { return }
        do {
            guard !lock.withLock({ closed }) else { throw DaemonTransportError.connectionLost }
            if lock.withLock({ process?.isRunning != true }) { try start() }
            guard !completion.isFinished else { stop(); close(); return }
            guard !lock.withLock({ closed }) else { throw DaemonTransportError.connectionLost }
            try input!.write(contentsOf: data + Data([10]))
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    guard newline <= DaemonWire.maxMessageBytes else { throw DaemonTransportError.payloadTooLarge }
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    completion.finish(.success(line)); return
                }
                guard buffer.count <= DaemonWire.maxMessageBytes else { throw DaemonTransportError.payloadTooLarge }
                let chunk = try readChunk(from: output!)
                guard !chunk.isEmpty else { throw DaemonTransportError.connectionLost }
                buffer.append(chunk)
            }
        } catch let error as DaemonTransportError { close(); completion.finish(.failure(error)) }
        catch { close(); completion.finish(.failure(DaemonTransportError.connectionLost)) }
    }
    private func start() throws {
        close()
        let child = Process(), requests = Pipe(), replies = Pipe()
        child.executableURL = executable
        child.arguments = ["--stdio", "--database", database] + additionalArguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TMPDIR": FileManager.default.temporaryDirectory.path]
        child.standardInput = requests; child.standardOutput = replies
        child.standardError = FileHandle.standardError
        try lock.withLock {
            guard !closed else { throw DaemonTransportError.connectionLost }
            try child.run()
            process = child
        }
        input = requests.fileHandleForWriting; output = replies.fileHandleForReading
        #if os(macOS)
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
    }
    func shutdown() {
        lock.withLock { closed = true }
        stop()
    }
    func stop() {
        lock.withLock {
            if let process, process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    func close() {
        stop()
        let child = lock.withLock { process }
        child?.waitUntilExit()
        try? input?.close(); try? output?.close()
        lock.withLock { process = nil }
        input = nil; output = nil; buffer.removeAll()
    }
}

private func readChunk(from handle: FileHandle) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = bytes.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno != EINTR { throw POSIXError(.EIO) }
    }
}
