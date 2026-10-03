import Darwin
import Foundation
import Observation
import ServiceManagement
@preconcurrency import XPC

// НЕ ПРОВЕРЕНО СБОРКОЙ.
// Клиент: `XPCSession(machService:options:)` с хвостом-замыканием отмены, затем
// `setPeerRequirement`, `activate`, `send` → `Result<XPCReceivedMessage, XPCRichError>`.
// Так устроен `XPCSession(xpcService:)` в Thaw (macOS 26); здесь имя параметра
// заменено на `machService`, потому что агент — LaunchAgent, а не .xpc-бандл.
// Если сигнатура другая, правьте только `ensureSession()` и `send(_:)`.

@MainActor
@Observable
final class SpikeAgentClient {
    static let shared = SpikeAgentClient()

    private(set) var phase = "idle"
    private(set) var serviceStatus = "unknown"
    private(set) var lines: [String] = []
    private(set) var events: [SpikeEvent] = []
    private(set) var lastSeq: UInt64 = 0
    private(set) var lastPid: Int32 = 0
    private(set) var lastBootID: String?
    private(set) var teamID = SigningProbe.teamIdentifier() ?? "нет (ad-hoc или без подписи)"
    var autoReconnect = true

    private let service = SMAppService.agent(plistName: SpikeIdentity.plistName)
    private var session: XPCSession?
    private var reconnectTask: Task<Void, Never>?
    private var connectInFlight = false
    private var backoffStep = 0
    private let backoffSteps: [Double] = [0.5, 1, 2, 5]
    private var statusPoll: Task<Void, Never>?

    var bundlePath: String { Bundle.main.bundlePath }
    var bundleVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var agentBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KabanSpikeAgent").path
    }

    var agentPlistPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(SpikeIdentity.plistName)")
            .path
    }

    var agentBinaryExists: Bool { FileManager.default.isExecutableFile(atPath: agentBinaryPath) }
    var agentPlistExists: Bool { FileManager.default.fileExists(atPath: agentPlistPath) }

    func startStatusPoll() {
        guard statusPoll == nil else { return }
        refreshStatus()
        statusPoll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshStatus()
            }
        }
    }

    func refreshStatus() {
        let text: String
        switch service.status {
        case .notRegistered:
            text = "notRegistered"
        case .enabled:
            text = "enabled"
        case .requiresApproval:
            text = "requiresApproval"
        case .notFound:
            text = "notFound"
        @unknown default:
            text = "unknown"
        }
        if text != serviceStatus {
            serviceStatus = text
            note("SMAppService.status → \(text)")
            if text == "requiresApproval" {
                phase = "needsApproval"
            }
        } else if serviceStatus == "unknown" {
            serviceStatus = text
        }
    }

    func register() {
        do {
            try service.register()
            note("register() вернулся без ошибки")
        } catch {
            note("register() ошибка: \(error.localizedDescription)")
        }
        refreshStatus()
    }

    func unregister() {
        do {
            try service.unregister()
            note("unregister() ок")
        } catch {
            note("unregister() ошибка: \(error.localizedDescription)")
        }
        session = nil
        phase = "idle"
        refreshStatus()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
        note("открыты Объекты входа")
    }

    func connect() {
        reconnectTask?.cancel()
        Task { await cycle(reason: "кнопка") }
    }

    func killAgent() {
        guard lastPid > 0 else {
            note("нет pid, некого останавливать")
            return
        }
        let result = kill(lastPid, SIGTERM)
        note("SIGTERM pid=\(lastPid) kill=\(result)")
    }

    func appendNote(_ text: String) {
        Task {
            do {
                let reply = try await send(.append(note: text))
                note("append → \(String(describing: reply))")
                await cycle(reason: "после append")
            } catch {
                note("append ошибка: \(error.localizedDescription)")
            }
        }
    }

    func trimJournal() {
        let threshold = lastSeq + 1
        Task {
            do {
                let reply = try await send(.trimBelow(seq: threshold))
                note("trimBelow \(threshold) → \(String(describing: reply))")
                await cycle(reason: "после trim")
            } catch {
                note("trim ошибка: \(error.localizedDescription)")
            }
        }
    }

    func askAgentToNotify(_ kind: SpikeNotificationKind) async -> String {
        do {
            let reply = try await send(.postNotification(kind: kind))
            let text = String(describing: reply)
            note("agent notification \(kind.rawValue): \(text)")
            return text
        } catch {
            let text = error.localizedDescription
            note("agent notification ошибка: \(text)")
            return text
        }
    }

    func handleCancel(_ text: String) {
        note("сессия отменена: \(text)")
        session = nil
        phase = "daemonUnavailable"
        scheduleReconnect()
    }

    private func cycle(reason: String) async {
        if connectInFlight {
            note("cycle пропущен, уже идёт (\(reason))")
            return
        }
        connectInFlight = true
        defer { connectInFlight = false }
        phase = "connecting"
        note("подключение (\(reason))")
        let started = Date()
        do {
            let pongReply = try await send(.ping)
            let pingMS = Date().timeIntervalSince(started) * 1000
            SpikeSignpost.event("FS1.Ping")
            guard case .pong(let pong) = pongReply else {
                note("ping неожиданный ответ \(String(describing: pongReply))")
                throw SpikeClientError.unexpectedReply
            }
            lastPid = pong.pid
            let bootChanged = lastBootID != nil && lastBootID != pong.bootID
            if bootChanged {
                note("bootID сменился \(lastBootID ?? "-") → \(pong.bootID)")
            }
            lastBootID = pong.bootID
            note(String(format: "pong %.1f мс pid=%d seq=%llu team=%@", pingMS, pong.pid, pong.seq, pong.teamID ?? "nil"))
            note("boot=\(pong.bootID) bundle=\(pong.bundleID ?? "nil")")
            phase = "catchingUp"
            let from = lastSeq
            let subReply = try await send(.subscribe(fromSeq: from))
            guard case .subscription(let sub) = subReply else {
                throw SpikeClientError.unexpectedReply
            }
            if sub.resyncRequired || bootChanged {
                phase = "resyncing"
                events = sub.events
                note("resyncRequired=\(sub.resyncRequired) bootChanged=\(bootChanged) \(sub.reason) events=\(sub.events.count)")
            } else {
                events.append(contentsOf: sub.events)
                note("catchup \(sub.reason) +\(sub.events.count)")
            }
            lastSeq = sub.nextSeq
            phase = "live"
            backoffStep = 0
        } catch {
            phase = "daemonUnavailable"
            session = nil
            note("цикл не удался: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard autoReconnect else {
            note("автопереподключение выключено")
            return
        }
        reconnectTask?.cancel()
        let delay = backoffSteps[min(backoffStep, backoffSteps.count - 1)]
        backoffStep += 1
        note(String(format: "повтор через %.1f с", delay))
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await cycle(reason: "backoff \(delay)s")
        }
    }

    private func ensureSession() throws -> XPCSession {
        if let session { return session }
        let created = try XPCSession(machService: SpikeIdentity.machService, options: .inactive) { error in
            let text = error.localizedDescription
            Task { @MainActor in
                SpikeAgentClient.shared.handleCancel(text)
            }
        }
        if SigningProbe.teamIdentifier() != nil {
            created.setPeerRequirement(.isFromSameTeam())
        }
        try created.activate()
        session = created
        note("XPCSession activate mach=\(SpikeIdentity.machService)")
        return created
    }

    private func send(_ request: SpikeRequest) async throws -> SpikeReply {
        let current = try ensureSession()
        let box = OnceBox()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try current.send(request) { (result: Result<XPCReceivedMessage, XPCRichError>) in
                    box.finish {
                        switch result {
                        case .success(let message):
                            do {
                                continuation.resume(returning: try message.decode(as: SpikeReply.self))
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                box.finish {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func note(_ message: String) {
        let line = message
        SpikeFileLog.append("fs1", line)
        lines.append(line)
        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
        }
    }
}

private enum SpikeClientError: LocalizedError {
    case unexpectedReply

    var errorDescription: String? { "неожиданный ответ агента" }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func finish(_ body: () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        body()
    }
}
