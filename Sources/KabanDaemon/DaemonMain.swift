import Foundation
import KabanProtocol
import KabanDaemonCore
#if os(macOS)
import Darwin
#else
import Glibc
#endif

@main
struct DaemonMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print("KabanDaemon --database PATH [--stdio]\nDefault: signed XPC Mach service app.kaban.agent (macOS 26+).\n--stdio: private development JSON-lines channel; no service registration.")
                return
            }
            guard let index = arguments.firstIndex(of: "--database"), arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--"),
                  arguments.count == (arguments.contains("--stdio") ? 3 : 2) else { throw HostError.arguments }
            let path = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.path
            if !arguments.contains("--stdio") {
                #if os(macOS)
                guard #available(macOS 26.0, *) else { throw HostError.platform }
                #else
                throw HostError.platform
                #endif
            }
            let lease = try WriterLease(path: path + ".daemon.lock")
            let store = try KabanStore(path: path)
            // Recovery changes running/gating invocations only. No external processes are spawned.
            _ = try store.recover(passId: UUID(), at: Date())
            let service = DaemonService(store: store)
            if arguments.contains("--stdio") {
                try withExtendedLifetime(lease) {
                    var buffer = Data()
                    while true {
                        if let newline = buffer.firstIndex(of: 10) {
                            guard newline <= DaemonWire.maxMessageBytes else { throw DaemonTransportError.payloadTooLarge }
                            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                            let response = service.handle(data: line)
                            try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                            continue
                        }
                        guard buffer.count <= DaemonWire.maxMessageBytes else { throw DaemonTransportError.payloadTooLarge }
                        let chunk = try readChunk(from: .standardInput)
                        if chunk.isEmpty {
                            guard buffer.isEmpty else { throw HostError.incompleteFrame }
                            break
                        }
                        buffer.append(chunk)
                    }
                }
                return
            }
            #if os(macOS)
            if #available(macOS 26.0, *) {
                let listener = try XPCDaemonListener(service: service)
                withExtendedLifetime((lease, listener)) { dispatchMain() }
            } else { throw HostError.platform }
            #else
            throw HostError.platform
            #endif
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("KabanDaemon: \(error)\n".utf8))
            exit(1)
        }
    }
}

private enum HostError: Error { case arguments, platform, writerAlreadyRunning, incompleteFrame }

private func readChunk(from handle: FileHandle) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = bytes.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno != EINTR { throw POSIXError(.EIO) }
    }
}

/// Only one daemon runtime may recover/execute a particular database at a time.
private final class WriterLease {
    private let descriptor: Int32
    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw HostError.writerAlreadyRunning }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw HostError.writerAlreadyRunning
        }
    }
    deinit { close(descriptor) }
}
