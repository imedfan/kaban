import Foundation
import Dispatch
import KabanProtocol
import KabanDaemonCore
import KabanTransport
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
                print("""
                KabanDaemon --launch-agent | --database PATH [--stdio] [--effect-pass] [--clone-pass] [--process-pass] [--mcp-pass] [--mcp-isolation-pass] [--stage-pass] [--merge-pass] [--log-pass] [--workspaces PATH] [--runner PATH] [--runner-arg ARG] [--cursor-agent PATH]
                Default: signed XPC Mach service app.kaban.agent (macOS 26+).
                --stdio: private development JSON-lines channel; no service registration.
                --effect-pass: acknowledge lifecycle effects after a post-commit side effect.
                Agent, gate, and merge effects stay pending. This pass does not run Cursor or git.
                --clone-pass: create reserved task clones and clean recorded clone paths. It does not start Cursor.
                --process-pass: run --runner in its own process group, stop that group, and classify a technical exit.
                It does not launch Cursor. Without --runner, pending starts stay pending. Timeout checks do not wait.
                --mcp-pass: one board complete_stage for a running task through the loopback MCP server, then reprint that line.
                --mcp-isolation-pass: restore each swapped .cursor/mcp.json and reprint that line. It does not launch Cursor.
                --stage-pass: run pending gates, hooks, result checks, and one stage commit, then reprint those lines. It does not launch Cursor.
                --merge-pass: rebase one approved task onto main and fast-forward that ref, then reprint those lines. It does not launch Cursor.
                --log-pass: reprint one stored log page per run through the same reader as readLog. It does not launch Cursor.
                --cursor-agent PATH: absolute executable checked with version, status and --list-models every 5 minutes and on recheck runner.
                It does not start a model prompt. Without this flag the daemon does not probe Cursor.
                """)
                return
            }
            let launchAgent = arguments == ["--launch-agent"]
            var positional = arguments
            if launchAgent {
                let installation = DaemonInstallation()
                _ = umask(0o077)
                try installation.prepare()
                let log = installation.logs.appendingPathComponent("daemon.log").path
                let fd = open(log, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                _ = dup2(fd, STDERR_FILENO); close(fd)
                positional = ["--database", installation.database.path, "--workspaces", installation.workspaces.path]
            }
            let initialize = launchAgent || positional.contains("--initialize")
            if initialize { _ = umask(0o077) }
            let stdio = positional.contains("--stdio")
            let effectPass = positional.contains("--effect-pass")
            let clonePass = positional.contains("--clone-pass")
            let processPass = positional.contains("--process-pass")
            let mcpPass = positional.contains("--mcp-pass")
            let isolationPass = positional.contains("--mcp-isolation-pass")
            let stagePass = positional.contains("--stage-pass")
            let mergePass = positional.contains("--merge-pass")
            let logPass = positional.contains("--log-pass")
            positional.removeAll { $0 == "--stdio" || $0 == "--initialize" || $0 == "--effect-pass" || $0 == "--clone-pass" || $0 == "--process-pass" || $0 == "--mcp-pass" || $0 == "--mcp-isolation-pass" || $0 == "--stage-pass" || $0 == "--merge-pass" || $0 == "--log-pass" }
            var workspaces: String?
            var runner: String?
            var runnerArguments: [String] = []
            var cursorAgent: String?
            var cursor = 0
            var kept: [String] = []
            while cursor < positional.count {
                let item = positional[cursor]
                func take() throws -> String {
                    guard cursor + 1 < positional.count, !positional[cursor + 1].hasPrefix("--") else { throw HostError.arguments }
                    cursor += 1
                    return positional[cursor]
                }
                if item == "--workspaces" { workspaces = try take() }
                else if item == "--runner" { runner = try take() }
                else if item == "--runner-arg" { runnerArguments.append(try take()) }
                else if item == "--cursor-agent" { cursorAgent = try take() }
                else { kept.append(item) }
                cursor += 1
            }
            positional = kept
            guard positional.count == 2, positional[0] == "--database", !positional[1].hasPrefix("--") else { throw HostError.arguments }
            let path = URL(fileURLWithPath: positional[1]).standardizedFileURL.path
            if !stdio {
                #if os(macOS)
                guard #available(macOS 26.0, *) else { throw HostError.platform }
                #else
                throw HostError.platform
                #endif
            }
            let lease = try WriterLease(path: path + ".daemon.lock")
            let store = try KabanStore(path: path)
            if initialize, try store.getSnapshot().settings == nil {
                _ = try store.setSettings(.init(maxConcurrentRuns: 4, quotaOptions: .init(enabled: false, consent: false)), commandId: UUID(), at: Date())
            }
            if logPass {
                let lines = try store.runLogPass()
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            // The board call has to see the live run. Recovery would otherwise end it first.
            if mcpPass {
                let lines = try store.runMCPPass(at: Date())
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            if isolationPass {
                let lines = try store.runMCPIsolationPass(at: Date())
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            // Gates have to finish on the live invocation. Recovery would otherwise emit a second run.
            if stagePass {
                let lines = try store.runStagePass(owner: "daemon", at: Date())
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            // The fast-forward has to finish on the live gating merge. Recovery would otherwise emit a second startMerge.
            if mergePass {
                let root = workspaces ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
                let lines = try store.runMergePass(owner: "daemon", at: Date(), workspaceRoot: root)
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            // Recovery changes running/gating invocations only. Git clone, cleanup, and process groups run only for their passes.
            try store.recoverProjectOperations()
            try store.recoverPipelineOperations()
            try store.refreshProjectLocations()
            try store.refreshPipelines()
            let diagnosticPass = effectPass || clonePass || processPass || mcpPass || isolationPass || stagePass || mergePass || logPass
            if diagnosticPass {
                _ = try store.recover(passId: UUID(), at: Date())
                _ = try store.recoverEffectExecution(at: Date(), reclaimUnexpired: true)
            } else {
                let root = workspaces ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
                _ = try store.recoverProduction(passId: UUID(), at: Date(), workspaceRoot: root)
            }
            if let cursorAgent { try store.setRunnerExecutable(cursorAgent) }
            if processPass {
                let root = workspaces ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
                let lines = try store.runProcessPass(owner: "daemon", at: Date(), workspaceRoot: root, runner: runner, runnerArguments: runnerArguments)
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            if effectPass {
                let lines = try store.runEffectPass(owner: "daemon", at: Date(), sideEffectLog: path + ".side-effects")
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            if clonePass {
                let root = workspaces ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
                let lines = try store.runClonePass(owner: "daemon", at: Date(), workspaceRoot: root)
                for line in lines {
                    try FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
                }
            }
            let runtimeRoot = diagnosticPass ? nil : (workspaces ?? URL(fileURLWithPath: path).deletingLastPathComponent().path)
            let scheduler = DaemonScheduler(store: store, workspaceRoot: runtimeRoot, runner: runner, runnerArguments: runnerArguments) { error in
                try? FileHandle.standardError.write(contentsOf: Data("KabanDaemon: scheduler pass failed: \(error)\n".utf8))
            }
            defer { scheduler.stop() }
            let service = DaemonService(store: store, wakeScheduler: { scheduler.wake() })
            let observer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.kaban.project-observer"))
            observer.schedule(deadline: .now() + 2, repeating: 2)
            observer.setEventHandler { @Sendable in
                try? store.refreshProjectLocations()
                try? store.refreshPipelines()
                scheduler.wake()
            }
            observer.resume()
            defer { observer.cancel() }
            if stdio {
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
                let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "app.kaban.termination"))
                signal(SIGTERM, SIG_IGN)
                termination.setEventHandler {
                    listener.cancel(); observer.cancel(); scheduler.stop()
                    if launchAgent, let runtimeRoot {
                        do { _ = try store.recoverProduction(passId: UUID(), at: Date(), workspaceRoot: runtimeRoot) }
                        catch { try? FileHandle.standardError.write(contentsOf: Data("KabanDaemon: shutdown recovery failed: \(error)\n".utf8)) }
                    }
                    exit(0)
                }
                termination.resume()
                withExtendedLifetime((lease, listener, observer, scheduler, termination)) { dispatchMain() }
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
