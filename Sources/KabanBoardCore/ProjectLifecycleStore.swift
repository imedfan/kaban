import Foundation
import Observation
import KabanProtocol

public enum ProjectOperation: Equatable, Sendable {
    case add, relink(ProjectID), remove(ProjectID)
    public var projectID: ProjectID? {
        switch self { case .add: nil; case .relink(let id), .remove(let id): id }
    }
}

public struct ProjectFormDraft: Codable, Equatable, Sendable {
    public var path = ""
    public var createTemplate = true
    public var identity = IdentityDraft()
    public var showsIdentity = false
    public var commandID: CommandID?
    public var handledCommandID: CommandID?
    public init() {}
}

/// Project forms retain input and command identity. Only BoardSession changes
/// projects; reads never infer git configuration or pipeline validity locally.
@MainActor @Observable public final class ProjectLifecycleStore {
    public let session: BoardSession
    private let client: any KabanClient
    private let storage: any KeyValueStoring
    private let key: String
    public private(set) var operation: ProjectOperation = .add
    public private(set) var draft = ProjectFormDraft()
    public private(set) var formError: String?
    public private(set) var connectedProjectID: ProjectID?
    public private(set) var branches: [String]?
    public private(set) var gates: [String]?
    public private(set) var environment: EnvironmentReport?
    public private(set) var branchesError: String?
    public private(set) var gatesError: String?
    public private(set) var environmentError: String?
    public private(set) var isReading = false
    private var refreshAgain = false
    private var diagnosticsGeneration: UUID?
    private var handledOutcome: CommandID?
    private var formGeneration = UUID()

    public init(client: any KabanClient, session: BoardSession, storage: any KeyValueStoring, key: String) {
        self.client = client; self.session = session; self.storage = storage; self.key = key
    }
    private var draftKey: String {
        switch operation { case .add: key + ".add"; case .relink(let id): key + ".relink." + id.rawValue; case .remove(let id): key + ".remove." + id.rawValue }
    }
    public var record: ClientCommandJournal.Record? { session.journal?.records.first { $0.envelope.commandId == draft.commandID } }
    public var phase: ClientCommandPhase? { record?.phase }
    public var isPending: Bool { record?.isPending == true }
    public var diagnosticsStale: Bool { !session.canSend || diagnosticsGeneration != session.sessionGeneration || branchesError != nil || gatesError != nil || environmentError != nil }
    private var command: Command {
        switch operation {
        case .add: .addProject(path: draft.path, createTemplate: draft.createTemplate, identity: draft.showsIdentity ? draft.identity.enteredIdentity : nil)
        case .relink(let id): .relinkProject(projectId: id, path: draft.path)
        case .remove(let id): .removeProject(projectId: id)
        }
    }
    private var hasRequiredPath: Bool { if case .remove = operation { return true }; return !draft.path.isEmpty }
    public var canSubmit: Bool {
        !isPending && phase != .applied && (operation == .add || operation.projectID.map { session.projection?.projects[$0] != nil } == true) &&
        hasRequiredPath && session.can(command)
    }
    public func open(_ value: ProjectOperation) {
        operation = value; formGeneration = UUID(); formError = nil; connectedProjectID = nil; handledOutcome = nil
        branches = nil; gates = nil; environment = nil; branchesError = nil; gatesError = nil; environmentError = nil; diagnosticsGeneration = nil
        do { draft = try storage.data(forKey: draftKey).map { try JSONDecoder().decode(ProjectFormDraft.self, from: $0) } ?? .init() }
        catch { draft = .init(); formError = "Не удалось прочитать черновик проекта. " + error.localizedDescription }
        if let pending = session.journal?.records.last(where: { $0.isPending && matches($0.envelope.command) }) {
            draft.commandID = pending.envelope.commandId
            switch pending.envelope.command {
            case .addProject(let path, let template, let identity):
                draft.path = path; draft.createTemplate = template; draft.showsIdentity = identity != nil
                if let identity { draft.identity = .init(identity: identity) }
            case .relinkProject(_, let path): draft.path = path
            default: break
            }
        } else if phase == .applied { draft = .init() }
        if draft.path.isEmpty, let id = value.projectID { draft.path = session.projection?.projects[id]?.path ?? "" }
        handledOutcome = draft.handledCommandID
        if case .rejected(let error) = phase { formError = error.code == CommandError.identityRequiredCode ? IdentityDraft.generalText : CommandErrorText.render(error) }
        observeOutcome(); persist()
    }
    private func matches(_ command: Command) -> Bool {
        switch (operation, command) {
        case (.add, .addProject): true
        case (.relink(let id), .relinkProject(let other, _)), (.remove(let id), .removeProject(let other)): id == other
        default: false
        }
    }
    public func editPath(_ value: String) { guard !isPending, phase != .applied else { return }; draft.path = value; persist() }
    public func setCreateTemplate(_ value: Bool) { guard !isPending, phase != .applied else { return }; draft.createTemplate = value; persist() }
    public func editIdentity(_ field: IdentityField, value: String) {
        guard !isPending, phase != .applied else { return }
        switch field { case .name: draft.identity.name.value = value; draft.identity.name.fromGitSettings = false; case .email: draft.identity.email.value = value; draft.identity.email.fromGitSettings = false }
        persist()
    }
    @discardableResult public func submit() async -> Bool {
        guard canSubmit else { return false }
        let envelope = CommandEnvelope(command: command), generation = formGeneration
        draft.commandID = envelope.commandId; draft.handledCommandID = nil; handledOutcome = nil; formError = nil
        guard persist() else { return false }
        let accepted = await session.send(envelope, editor: true)
        guard generation == formGeneration else { return accepted }
        if record == nil { draft.commandID = nil; formError = session.editorError ?? "Отправка недоступна. Перепроверьте соединение."; persist() }
        observeOutcome()
        return accepted
    }
    /// Called when the journal changes, including event-before-reply/reconnect.
    public func observeOutcome() {
        guard let record, matches(record.envelope.command), handledOutcome != record.envelope.commandId else { return }
        switch record.phase {
        case .rejected(let error):
            handledOutcome = record.envelope.commandId; draft.handledCommandID = record.envelope.commandId; formError = error.code == CommandError.identityRequiredCode ? IdentityDraft.generalText : CommandErrorText.render(error)
            if error.code == CommandError.identityRequiredCode, case .addProject(_, _, let submitted) = record.envelope.command {
                draft.showsIdentity = true; draft.identity = draft.identity.refusing(error, submitted: submitted)
            }
            // This form owns the refusal; do not show a second board-wide alert.
            if session.error == error.message { session.error = nil }
            if session.editorError == error.message { session.editorError = nil }
            persist()
        case .applied:
            handledOutcome = record.envelope.commandId; formError = nil
            if operation == .add {
                connectedProjectID = record.createdProjectID
                if connectedProjectID == nil, case .addProject(let path, _, _) = record.envelope.command {
                    // Retained receipt proves the mutation, but canonical aliases
                    // cannot be guessed. Only an exact normalized path match selects.
                    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                    connectedProjectID = session.projection?.projectOrder.first { session.projection?.projects[$0]?.path == normalized }
                }
            } else { connectedProjectID = operation.projectID }
        default: break
        }
    }
    @discardableResult private func persist() -> Bool {
        do { storage.set(try JSONEncoder().encode(draft), forKey: draftKey); return true }
        catch { formError = "Не удалось сохранить черновик проекта. " + error.localizedDescription; return false }
    }
    public func refreshDiagnostics() async {
        if isReading { refreshAgain = true; return }
        guard let id = connectedProjectID ?? operation.projectID, session.canSend, session.projection?.projects[id] != nil else { return }
        isReading = true; defer {
            isReading = false
            if refreshAgain { refreshAgain = false; Task { await self.refreshDiagnostics() } }
        }
        let generation = session.sessionGeneration, form = formGeneration
        func valid() -> Bool { generation == session.sessionGeneration && form == formGeneration && session.canSend && session.projection?.projects[id] != nil }
        if session.can(CommandName.listBranches) {
            do { let value = try await read(.listBranches(projectId: id)); guard valid() else { return }; guard case .branches(let items) = value else { throw invalidReply() }; branches = items; branchesError = nil }
            catch { if valid() { branchesError = message(error) } }
        } else { branchesError = "Служба не поддерживает список веток." }
        guard valid() else { return }
        if session.can(CommandName.detectGates) {
            do { let value = try await read(.detectGates(projectId: id)); guard valid() else { return }; guard case .gates(let items) = value else { throw invalidReply() }; gates = items; gatesError = nil }
            catch { if valid() { gatesError = message(error) } }
        } else { gatesError = "Служба не поддерживает поиск команд гейтов." }
        guard valid() else { return }
        if session.can(CommandName.checkEnvironment) {
            do { let value = try await read(.checkEnvironment); guard valid() else { return }; guard case .environment(let report) = value else { throw invalidReply() }; environment = report; environmentError = nil }
            catch { if valid() { environmentError = message(error) } }
        } else { environmentError = "Готовность Cursor неизвестна: служба не поддерживает проверку окружения. Backlog доступен." }
        if valid() { diagnosticsGeneration = generation }
    }
    private func read(_ command: Command) async throws -> CommandResult {
        let envelope = CommandEnvelope(command: command)
        let reply = try await client.send(envelope)
        guard reply.commandId == envelope.commandId else { throw invalidReply() }
        if case .error(let failure) = reply.result { throw failure }
        return reply.result
    }
    private func invalidReply() -> CommandError { .init(code: "invalid_reply", message: "Некорректный ответ службы о проекте.") }
    private func message(_ error: Error) -> String { (error as? CommandError).map { CommandErrorText.render($0) } ?? error.localizedDescription }
}
