import Foundation
import Observation
import KabanProtocol

@MainActor @Observable public final class ProjectMCPStore {
    public enum CatalogState: Equatable { case unknown, loading, loaded([McpServerRef]), failed(String) }
    public let projectID: ProjectID
    public let session: BoardSession
    private let client: any KabanClient
    @ObservationIgnored private var readID = UUID()
    public private(set) var catalogState: CatalogState = .unknown
    public private(set) var commandID: CommandID?
    public private(set) var error: String?
    public var project: ProjectSummary? { session.projection?.projects[projectID] }
    public var allowed: [String]? { project?.mcpAllowlist }
    public var catalog: [McpServerRef]? { if case .loaded(let values) = catalogState { return values }; return nil }
    public var receipt: ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.first { $0.envelope.commandId == commandID }
    }
    public var pending: Bool { session.pending(in: .project(projectID)) != nil }
    public var missingAllowed: [String] {
        guard let catalog, let allowed else { return [] }
        return allowed.filter { name in name != "kaban" && !catalog.contains(where: { $0.name == name }) }
    }
    public var canEdit: Bool {
        catalog != nil && allowed != nil && !pending && session.pending(in: .pipeline(projectID)) == nil
            && session.can(.setProjectMcpAllowlist(projectId: projectID, servers: []))
    }
    public init(projectID: ProjectID, client: any KabanClient, session: BoardSession) {
        self.projectID = projectID; self.client = client; self.session = session
    }
    public func load() async {
        let token = UUID(); readID = token
        guard let project, session.can(CommandName.listProjectMcpServers) else {
            catalogState = .failed("Чтение MCP недоступно. Подключитесь к службе Kaban с поддержкой этой команды."); return
        }
        let generation = session.sessionGeneration, path = project.path
        catalogState = .loading
        let envelope = CommandEnvelope(command: .listProjectMcpServers(projectId: projectID))
        do {
            let reply = try await client.send(envelope)
            guard token == readID else { return }
            guard !Task.isCancelled, session.sessionGeneration == generation, session.canSend, self.project?.path == path else { catalogState = .unknown; return }
            guard reply.commandId == envelope.commandId else { throw CommandError(code: "invalid_reply", message: "Список MCP относится к другой команде.") }
            if case .error(let failure) = reply.result { throw failure }
            guard case .mcpServers(let servers) = reply.result else { throw CommandError(code: "invalid_reply", message: "Служба не вернула список MCP.") }
            catalogState = .loaded(servers); error = nil
        } catch {
            guard token == readID else { return }
            guard !Task.isCancelled, session.sessionGeneration == generation, session.canSend, self.project?.path == path else { catalogState = .unknown; return }
            catalogState = .failed((error as? CommandError)?.message ?? "Не удалось прочитать список MCP. Повторите запрос.")
        }
    }
    public func selectedStages(_ name: String) -> [String] {
        session.projection?.pipelines[projectID]?.stages.filter { $0.mcp?.contains(name) == true }.map(\.name) ?? []
    }
    @discardableResult public func setAllowed(_ name: String, enabled: Bool) async -> Bool {
        guard name != "kaban", canEdit, let allowed, let catalog else { return false }
        if enabled && !catalog.contains(where: { $0.name == name }) { return false }
        var names = Set(allowed)
        if enabled { names.insert(name) } else { names.remove(name) }
        return await save(names)
    }
    @discardableResult public func removeMissingPermissions() async -> Bool {
        guard canEdit, let allowed, let catalog else { return false }
        return await save(Set(allowed.filter { name in name == "kaban" || catalog.contains { $0.name == name } }))
    }
    private func save(_ names: Set<String>) async -> Bool {
        guard let catalog else { return false }
        let missing = names.filter { name in name != "kaban" && !catalog.contains { $0.name == name } }
        guard missing.isEmpty else { error = "Сначала удалите отсутствующие разрешения: " + missing.sorted().joined(separator: ", "); return false }
        let envelope = CommandEnvelope(command: .setProjectMcpAllowlist(projectId: projectID, servers: catalog.filter { $0.name != "kaban" && names.contains($0.name) }))
        commandID = envelope.commandId; error = nil
        let accepted = await session.send(envelope, editor: true)
        if !accepted { error = session.editorError ?? session.error ?? "Изменение MCP не подтверждено." }
        return accepted
    }
}
