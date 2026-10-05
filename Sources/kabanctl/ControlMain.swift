import Foundation
import KabanProtocol
import KabanTransport
#if os(macOS)
import Darwin
#else
import Glibc
#endif

@main
struct ControlMain {
    static func main() async {
        // A terminated development daemon must produce a transport error, not kill this CLI.
        signal(SIGPIPE, SIG_IGN)
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print("""
                kabanctl [--stdio-daemon EXECUTABLE --database PATH] snapshot
                kabanctl [transport options] send ENVELOPE.json
                kabanctl [transport options] subscribe SEQ
                kabanctl [transport options] watch [SEQ]
                Default transport: signed XPC, macOS 26+. send preserves the supplied commandId.
                watch emits snapshot/event JSON lines; resync replaces state with a new snapshot.
                """)
                return
            }
            let transport: any DaemonTransport
            var stdio: StdioDaemonTransport?
            if arguments.first == "--stdio-daemon" {
                guard arguments.count >= 5, arguments[2] == "--database" else { throw CLIError.arguments }
                let child = StdioDaemonTransport(executable: URL(fileURLWithPath: arguments[1]), database: arguments[3])
                stdio = child; transport = child; arguments.removeFirst(4)
            } else {
                #if os(macOS)
                if #available(macOS 26.0, *) { transport = XPCDaemonTransport() }
                else { throw CLIError.platform }
                #else
                throw CLIError.platform
                #endif
            }
            let client = DaemonClient(transport: transport)
            do {
                switch arguments.first {
                case "snapshot" where arguments.count == 1: try printJSON(await client.getSnapshot())
                case "send" where arguments.count == 2:
                    let envelope = try DaemonWire.decode(CommandEnvelope.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
                    let reply = try await client.send(envelope)
                    try printJSON(reply)
                    if case .error = reply.result { throw CLIError.refused }
                case "subscribe" where arguments.count == 2:
                    guard let seq = Seq(arguments[1]), seq >= 0 else { throw CLIError.arguments }
                    try printJSON(await client.subscribe(fromSeq: seq))
                case "watch" where arguments.count == 1 || arguments.count == 2:
                    let seq: Seq?
                    if arguments.count == 2 {
                        guard let value = Seq(arguments[1]), value >= 0 else { throw CLIError.arguments }
                        seq = value
                    } else { seq = nil }
                    for try await update in client.updates(after: seq) {
                        switch update {
                        case .snapshot(let snapshot): try printJSON(DaemonResponse(.snapshot(snapshot)))
                        case .event(let event): try printJSON(event)
                        }
                    }
                default: throw CLIError.arguments
                }
                await stdio?.close()
            } catch { await stdio?.close(); throw error }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("kabanctl: \(error)\n".utf8))
            exit(1)
        }
    }
    private static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try DaemonWire.encode(value)
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
private enum CLIError: Error { case arguments, platform, refused }
