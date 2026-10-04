import Darwin
import Foundation
import UserNotifications
@preconcurrency import XPC

// НЕ ПРОВЕРЕНО СБОРКОЙ. Слушатель Mach-сервиса — форма, которая собирается у приложений
// на macOS 26 (`XPCListener(service:requirement:)` / `request.accept`).
// MicGuard (2026) пишет, что `XPCListener(service:)` работает, когда имя есть в bootstrap
// launchd. Если линковщик скажет, что нет `init(service:requirement:)`, см. README,
// раздел «Если не собирается».

@main
struct AgentMain {
    static func main() {
        let server = AgentServer()
        do {
            let listener = try makeListener(server: server)
            SpikeFileLog.append(
                "agent",
                "listener up pid=\(ProcessInfo.processInfo.processIdentifier) boot=\(server.bootID) team=\(SigningProbe.teamIdentifier() ?? "none")"
            )
            withExtendedLifetime(listener) {
                dispatchMain()
            }
        } catch {
            SpikeFileLog.append("agent", "listener failed: \(error.localizedDescription)")
            fputs("KabanSpikeAgent: \(error)\n", stderr)
            exit(1)
        }
    }
}

private func makeListener(server: AgentServer) throws -> XPCListener {
    let name = SpikeIdentity.machService
    if SigningProbe.teamIdentifier() == nil {
        SpikeFileLog.append("agent", "no Team ID, listener without same-team requirement")
        return try XPCListener(service: name) { request in
            request.accept { message in
                server.handle(message)
            }
        }
    }
    return try XPCListener(service: name, requirement: .isFromSameTeam()) { request in
        request.accept { message in
            server.handle(message)
        }
    }
}

final class AgentServer: @unchecked Sendable {
    let bootID = UUID().uuidString
    private let lock = NSLock()
    private var events: [SpikeEvent] = []
    private var nextSeq: UInt64 = 1

    init() {
        appendLocked(kind: "boot", note: "agent started")
    }

    func handle(_ message: XPCReceivedMessage) -> SpikeReply {
        do {
            let request = try message.decode(as: SpikeRequest.self)
            return handle(request)
        } catch {
            SpikeFileLog.append("agent", "decode failed: \(error.localizedDescription)")
            return .failed("decode: \(error.localizedDescription)")
        }
    }

    private func handle(_ request: SpikeRequest) -> SpikeReply {
        switch request {
        case .ping:
            return .pong(pong())
        case .subscribe(let fromSeq):
            return .subscription(subscribe(fromSeq: fromSeq))
        case .append(let note):
            let event = append(kind: "note", note: note)
            return .appended(seq: event.seq)
        case .trimBelow(let seq):
            let snapshot = trim(below: seq)
            return .trimmed(remaining: snapshot.count, minSeq: snapshot.first?.seq ?? 0)
        case .postNotification(let kind):
            return .notificationAttempt(postNotification(kind))
        }
    }

    private func pong() -> SpikePong {
        lock.lock()
        let seq = events.last?.seq ?? 0
        lock.unlock()
        return SpikePong(
            pid: ProcessInfo.processInfo.processIdentifier,
            bootID: bootID,
            seq: seq,
            teamID: SigningProbe.teamIdentifier(),
            bundleID: Bundle.main.bundleIdentifier
        )
    }

    private func subscribe(fromSeq: UInt64) -> SpikeSubscription {
        lock.lock()
        let snapshot = events
        lock.unlock()
        let maxSeq = snapshot.last?.seq ?? 0
        let minSeq = snapshot.first?.seq ?? 0
        if fromSeq == 0 {
            return SpikeSubscription(
                bootID: bootID,
                events: snapshot,
                nextSeq: maxSeq,
                resyncRequired: false,
                reason: "snapshot"
            )
        }
        if snapshot.isEmpty || fromSeq > maxSeq || fromSeq + 1 < minSeq {
            let reason: String
            if snapshot.isEmpty {
                reason = "journal empty, client seq \(fromSeq)"
            } else if fromSeq > maxSeq {
                reason = "boot journal behind client seq \(fromSeq), max \(maxSeq)"
            } else {
                reason = "gap: client wants \(fromSeq + 1), retained from \(minSeq)"
            }
            SpikeFileLog.append("agent", "resyncRequired \(reason)")
            return SpikeSubscription(
                bootID: bootID,
                events: snapshot,
                nextSeq: maxSeq,
                resyncRequired: true,
                reason: reason
            )
        }
        let tail = snapshot.filter { $0.seq > fromSeq }
        return SpikeSubscription(
            bootID: bootID,
            events: tail,
            nextSeq: maxSeq,
            resyncRequired: false,
            reason: "catchup \(tail.count)"
        )
    }

    private func append(kind: String, note: String) -> SpikeEvent {
        lock.lock()
        defer { lock.unlock() }
        return appendLocked(kind: kind, note: note)
    }

    private func appendLocked(kind: String, note: String) -> SpikeEvent {
        let event = SpikeEvent(seq: nextSeq, kind: kind, note: note)
        nextSeq += 1
        events.append(event)
        return event
    }

    private func trim(below threshold: UInt64) -> [SpikeEvent] {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll { $0.seq < threshold }
        SpikeFileLog.append("agent", "trimmed below \(threshold), remaining \(events.count)")
        return events
    }

    /// Спайк 4 / FS-6: может ли процесс агента сам показать уведомление.
    /// CREATE_INFOPLIST_SECTION_IN_BINARY даёт бинарю bundle id. Хватит ли этого
    /// `UNUserNotificationCenter`, здесь не проверялось.
    private func postNotification(_ kind: SpikeNotificationKind) -> SpikeNotificationAttempt {
        let box = AttemptBox()
        let start = {
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = "KabanSpikeAgent"
            content.body = kind == .incident ? "Инцидент из агента" : "Вопрос из агента"
            if kind == .incident {
                content.interruptionLevel = .timeSensitive
            }
            content.threadIdentifier = "kaban-spike-agent"
            let request = UNNotificationRequest(
                identifier: "agent-\(kind.rawValue)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    box.finish(ok: false, message: "auth: \(error.localizedDescription)", kind: kind)
                    return
                }
                guard granted else {
                    box.finish(ok: false, message: "auth denied", kind: kind)
                    return
                }
                center.add(request) { error in
                    if let error {
                        box.finish(ok: false, message: "add: \(error.localizedDescription)", kind: kind)
                    } else {
                        box.finish(
                            ok: true,
                            message: "posted bundle=\(Bundle.main.bundleIdentifier ?? "nil")",
                            kind: kind
                        )
                    }
                }
            }
        }
        if Thread.isMainThread {
            start()
            return SpikeNotificationAttempt(
                ok: false,
                message: "обработчик на главном потоке, результат в session.log"
            )
        }
        DispatchQueue.main.async(execute: start)
        return box.wait()
    }
}

private final class AttemptBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value = SpikeNotificationAttempt(ok: false, message: "timeout")

    func finish(ok: Bool, message: String, kind: SpikeNotificationKind) {
        let attempt = SpikeNotificationAttempt(ok: ok, message: message)
        lock.lock()
        value = attempt
        lock.unlock()
        SpikeFileLog.append("agent", "notification \(kind.rawValue) ok=\(ok) \(message)")
        semaphore.signal()
    }

    func wait() -> SpikeNotificationAttempt {
        _ = semaphore.wait(timeout: .now() + 5)
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
