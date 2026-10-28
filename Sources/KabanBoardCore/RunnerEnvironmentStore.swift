import Foundation
import Observation
import KabanProtocol

/// Read-only environment facts belong to the daemon. Config changes use the
/// same durable session journal as every other application mutation.
@MainActor @Observable public final class RunnerEnvironmentStore {
    private let client: any KabanClient
    public let session: BoardSession
    public private(set) var report: EnvironmentReport?
    private var readConfiguration: CursorEnvironment?
    public var configuration: CursorEnvironment? { session.cursorEnvironment ?? readConfiguration }
    public private(set) var checkedAt: Date?
    public private(set) var isChecking = false
    public private(set) var reportError: String?
    public private(set) var configurationError: String?
    public private(set) var draftPath = ""
    public private(set) var isEdited = false
    public private(set) var submittedCommandID: CommandID?
    private var reportGeneration: UUID?
    private var configurationGeneration: UUID?
    private var refreshAgain = false
    private var submittedConfiguration: CursorEnvironment?
    private var reportEnvironmentSeq: Seq?

    public init(client: any KabanClient, session: BoardSession) {
        self.client = client; self.session = session
        if let record = session.journal?.records.last(where: {
            if case .configureCursor = $0.envelope.command { return $0.isPending }; return false
        }), case .configureCursor(let value) = record.envelope.command {
            submittedCommandID = record.envelope.commandId; submittedConfiguration = value
            draftPath = value.executablePath ?? ""; isEdited = true
        }
    }
    public var isStale: Bool { report != nil && (reportError != nil || !session.canSend || reportGeneration != session.sessionGeneration || reportEnvironmentSeq != session.cursorEnvironmentSeq) }
    public var canConfigure: Bool {
        configuration != nil && configurationError == nil && configurationGeneration == session.sessionGeneration &&
        !isChecking && isEdited && session.can(.configureCursor(environment: draftConfiguration))
    }
    public var configurationUnavailableReason: String? {
        if let configurationError { return configurationError }
        if session.canSend && !session.can(CommandName.configureCursor) {
            return "Подключённая служба не поддерживает настройку пути Cursor."
        }
        return nil
    }
    public var canRecheck: Bool {
        session.can(.recheck(scope: .runner)) &&
        session.capabilities?.commands.first { $0.name == CommandName.recheck.rawValue }?.scopes?.contains("runner") == true
    }
    public var submissionPhase: ClientCommandPhase? {
        _ = session.pendingRecords
        return session.journal?.records.first { $0.envelope.commandId == submittedCommandID }?.phase
    }
    private var draftConfiguration: CursorEnvironment {
        .init(executablePath: draftPath.isEmpty ? nil : draftPath)
    }
    public func editPath(_ path: String) { draftPath = path; isEdited = true }

    /// Coalesces requests, without cancelling an in-flight shared stdio RPC.
    public func refresh() async {
        if isChecking { refreshAgain = true; return }
        isChecking = true; defer { isChecking = false }
        repeat {
            refreshAgain = false
            guard session.canSend else { return }
            let generation = session.sessionGeneration
            let environmentSeq = session.cursorEnvironmentSeq
            if session.can(CommandName.getCursorEnvironment) {
                do {
                    let reply = try await read(.getCursorEnvironment)
                    guard valid(generation) else { continue }
                    guard case .cursorEnvironment(let value) = reply else { throw invalidReply() }
                    guard environmentSeq == session.cursorEnvironmentSeq else { refreshAgain = true; continue }
                    // A query can arrive after commit but before journal delivery.
                    // Keep the old applied path until the mutation is confirmed.
                    if session.pending(in: .global)?.envelope.command.name != .configureCursor {
                        readConfiguration = value
                    }
                    configurationGeneration = generation; configurationError = nil
                    if !isEdited || (submissionPhase == .applied && draftConfiguration == submittedConfiguration) {
                        draftPath = configuration?.executablePath ?? ""; isEdited = false
                    }
                } catch { if valid(generation) { configurationError = message(error) } }
            } else {
                configurationError = "Служба пока не поддерживает чтение и настройку пути Cursor. Обновите службу Kaban."
            }
            guard valid(generation) else { continue }
            if session.can(CommandName.checkEnvironment) {
                do {
                    let reply = try await read(.checkEnvironment)
                    guard valid(generation) else { continue }
                    guard case .environment(let value) = reply else { throw invalidReply() }
                    guard environmentSeq == session.cursorEnvironmentSeq else { refreshAgain = true; continue }
                    reportEnvironmentSeq = environmentSeq
                    report = value; reportGeneration = generation; checkedAt = Date(); reportError = nil
                } catch { if valid(generation) { reportError = message(error) } }
            } else {
                reportError = "Служба пока не поддерживает проверку окружения Cursor. Готовность запусков неизвестна. Задачи можно хранить в Backlog."
            }
        } while refreshAgain
    }
    @discardableResult public func savePath() async -> Bool {
        guard canConfigure else { return false }
        let value = draftConfiguration
        let envelope = CommandEnvelope(command: .configureCursor(environment: value))
        submittedCommandID = envelope.commandId; submittedConfiguration = value
        return await session.send(envelope, editor: true)
    }
    @discardableResult public func recheck() async -> Bool {
        guard canRecheck else { return false }
        return await session.send(.recheck(scope: .runner))
    }
    public var runnerReason: RunnerUnavailableReason? {
        session.projection?.ephemeral.schedulerFlags.compactMap { flag in
            if case .runnerUnavailable(let value) = flag { return value }; return nil
        }.first
    }
    private func valid(_ generation: UUID) -> Bool { session.canSend && generation == session.sessionGeneration }
    private func read(_ command: Command) async throws -> CommandResult {
        let envelope = CommandEnvelope(command: command)
        let reply = try await client.send(envelope)
        guard reply.commandId == envelope.commandId else { throw invalidReply() }
        if case .error(let failure) = reply.result { throw failure }
        return reply.result
    }
    private func invalidReply() -> CommandError { .init(code: "invalid_reply", message: "Служба вернула некорректный ответ о среде Cursor.") }
    private func message(_ error: Error) -> String { (error as? CommandError)?.message ?? error.localizedDescription }
}
