import Foundation
import Observation
import KabanProtocol

@MainActor @Observable public final class ProjectSettingsStore {
    public enum Section: Hashable { case identity, resources }
    public let projectID: ProjectID
    public private(set) var section: Section?
    public private(set) var identity = IdentityDraft()
    public private(set) var weight = ""
    public private(set) var maxRuns = ""
    public private(set) var error: String?
    public private(set) var commandID: CommandID?
    private let session: BoardSession
    private var handledCommandID: CommandID?
    private var initialized: Set<Section> = []
    public init(projectID: ProjectID, session: BoardSession) {
        self.projectID = projectID; self.session = session
    }
    public var project: ProjectSummary? { session.projection?.projects[projectID] }
    public var record: ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.first { $0.envelope.commandId == commandID }
    }
    public var isPending: Bool { session.pending(in: .project(projectID)) != nil }
    public var canSubmit: Bool {
        guard section != nil, project != nil, !isPending else { return false }
        return session.can(section == .identity ? CommandName.setProjectIdentity : .setProjectWeight)
    }
    public func begin(_ section: Section) {
        guard !isPending, self.section != section else { return }
        self.section = section; commandID = nil; error = nil
        if initialized.insert(section).inserted {
            if section == .identity { identity = .init(identity: project?.identity) }
            else {
                weight = project.map { String($0.weight) } ?? ""
                maxRuns = project?.maxRuns.map(String.init) ?? ""
            }
        }
    }
    public func cancel() { guard !isPending else { return }; if let section { initialized.remove(section) }; section = nil; error = nil }
    public func editIdentity(_ field: IdentityField, value: String) {
        guard !isPending else { return }
        guard (field == .name ? identity.name.value : identity.email.value) != value else { return }
        if field == .name { identity.name = .init(value: value) } else { identity.email = .init(value: value) }
        identity.focus = nil; identity.generalMessage = nil; error = nil
    }
    public func editWeight(_ value: String) { guard !isPending, weight != value else { return }; weight = value; error = nil }
    public func editMaxRuns(_ value: String) { guard !isPending, maxRuns != value else { return }; maxRuns = value; error = nil }
    @discardableResult public func submit() async -> Bool {
        guard canSubmit, let section else { return false }
        let command: Command
        switch section {
        case .identity: command = .setProjectIdentity(projectId: projectID, identity: identity.enteredIdentity)
        case .resources:
            guard let parsedWeight = Int(weight), maxRuns.isEmpty || Int(maxRuns) != nil else {
                error = "Введите целое число. Пустой личный максимум снимает лимит проекта."; return false
            }
            command = .setProjectWeight(projectId: projectID, weight: parsedWeight, maxRuns: maxRuns.isEmpty ? nil : Int(maxRuns))
        }
        let envelope = CommandEnvelope(command: command)
        commandID = envelope.commandId; handledCommandID = nil; error = nil
        let sent = await session.send(envelope, editor: true)
        observeOutcome()
        if record == nil { error = session.editorError ?? "Отправка недоступна. Ввод сохранён." }
        return sent
    }
    public func observeOutcome() {
        guard let record, record.envelope.commandId != handledCommandID else { return }
        switch record.phase {
        case .applied:
            handledCommandID = record.envelope.commandId
            if let section { initialized.remove(section) }
            section = nil; error = nil
        case .rejected(let failure):
            handledCommandID = record.envelope.commandId
            error = CommandErrorText.render(failure)
            if case .setProjectIdentity(_, let submitted) = record.envelope.command {
                identity = identity.refusing(failure, submitted: submitted)
                error = identity.generalMessage
            }
            if session.error == failure.message { session.error = nil }
            if session.editorError == failure.message { session.editorError = nil }
        default: break
        }
    }
}
