import Foundation
import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class ProjectMCPTests: XCTestCase {
    @MainActor func testPermissionsAwaitCorrelatedProjectEventAndNeverToggleKaban() async throws {
        let client = MCPTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "mcp")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let settings = ProjectMCPStore(projectID: Fix.project, client: client, session: session)
        await settings.load()
        XCTAssertEqual(settings.catalog?.count, 2)
        let board = await settings.setAllowed("kaban", enabled: false); XCTAssertFalse(board)
        let accepted = await settings.setAllowed("shared", enabled: true); XCTAssertTrue(accepted)
        XCTAssertEqual(settings.allowed, ["kaban"])
        XCTAssertEqual(settings.receipt?.phase, .awaitingEvent)
        XCTAssertEqual(client.sent.last?.command, .setProjectMcpAllowlist(projectId: Fix.project, servers: client.servers))
        let id = try XCTUnwrap(settings.commandID)
        client.continuation?.yield(.init(seq: 11, at: Date(), projectId: "other", commandId: id,
            event: .projectUpdated(.init(id: "other", name: "Other", path: "/other", mascotSeed: "other", mcpAllowlist: ["kaban", "shared"]))))
        try await wait { session.projection?.stateSeq == 11 }
        XCTAssertEqual(settings.receipt?.phase, .awaitingEvent); XCTAssertEqual(settings.allowed, ["kaban"])
        var project = try XCTUnwrap(settings.project); project.mcpAllowlist = ["kaban", "shared"]
        client.continuation?.yield(.init(seq: 12, at: Date(), projectId: Fix.project, commandId: id, event: .projectUpdated(project)))
        try await wait { settings.receipt?.phase == .applied }
        XCTAssertEqual(settings.allowed, ["kaban", "shared"])
        client.failure = .init(code: "mcp_config_unreadable", message: "Cannot read personal MCP", params: ["source": "personal"])
        await settings.load()
        XCTAssertEqual(settings.catalogState, .failed("Cannot read personal MCP")); XCTAssertNil(settings.catalog); XCTAssertFalse(settings.canEdit)
    }
    @MainActor func testLateCatalogCannotCrossConnectionAndPipelineKeepsDisabledSelection() async throws {
        let client = MCPTestClient(), session = BoardSession(client: client, storage: MemoryKeyValueStore(), key: "mcp-late")
        let loop = Task { await session.run() }; defer { loop.cancel() }
        try await wait { session.canSend }
        let settings = ProjectMCPStore(projectID: Fix.project, client: client, session: session)
        let editor = PipelineEditorStore(projectID: Fix.project, client: client, session: session)
        await editor.readSource()
        XCTAssertEqual(editor.document.stringList("stages[0].agent.mcp"), ["kaban", "disabled"])
        XCTAssertTrue(editor.canApply)
        let exact = editor.content
        editor.setMCPServer("disabled", path: "stages[0].agent.mcp", selected: true)
        XCTAssertEqual(editor.content, exact)
        editor.setMCPServer("kaban", path: "stages[0].agent.mcp", selected: false)
        XCTAssertEqual(editor.content, exact)
        var project = try XCTUnwrap(settings.project); project.mcpAllowlist = ["kaban", "shared"]
        _ = session.projection?.apply(.init(seq: 11, at: Date(), projectId: Fix.project, event: .projectUpdated(project)))
        XCTAssertFalse(editor.canApply)
        await editor.validate(); XCTAssertTrue(editor.canApply)
        editor.setMCPServer("shared", path: "stages[0].agent.mcp", selected: true)
        XCTAssertEqual(editor.document.stringList("stages[0].agent.mcp"), ["kaban", "disabled", "shared"])
        XCTAssertTrue(editor.content.contains("# exact 👋\r\n")); XCTAssertTrue(editor.content.contains("future: keep"))
        client.holdRead = true
        let read = Task { await settings.load() }
        try await wait { client.held != nil }
        client.throwRead = true
        session.stop(); client.held?.resume(); client.held = nil
        await read.value
        XCTAssertNil(settings.catalog); XCTAssertEqual(settings.catalogState, .unknown); XCTAssertFalse(settings.canEdit)
        XCTAssertEqual(editor.document.stringList("stages[0].agent.mcp"), ["kaban", "disabled", "shared"])
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw CommandError(code: "timeout", message: "MCP test timed out")
    }
}

@MainActor private final class MCPTestClient: KabanClient {
    let servers: [McpServerRef] = [.init(name: "shared", source: .project), .init(name: "shared", source: .personal)]
    let content = "# exact 👋\r\nstages:\r\n  - {id: dev, kind: agent, agent: {model: explicit, mcp: [kaban, disabled], future: keep}}\r\n"
    var sent: [CommandEnvelope] = []
    var failure: CommandError?
    var holdRead = false
    var throwRead = false
    var held: CheckedContinuation<Void, Never>?
    var continuation: AsyncStream<EventEnvelope>.Continuation?
    func getSnapshot() async throws -> Snapshot {
        var snapshot = Fix.snapshot(); snapshot.projects[0].mcpAllowlist = ["kaban"]
        snapshot.pipelines[0].sourceHash = "s1"; return snapshot
    }
    func synchronize() async throws -> SnapshotReplacement { .init(snapshot: try await getSnapshot(), cursor: .init(sessionId: UUID(), offset: 0), current: []) }
    func capabilities() async throws -> DaemonCapabilities {
        .init(operations: ["snapshot", "command", "subscribe", "synchronize"].map { .init(name: $0, supported: true) },
              commands: CommandName.allCases.map { .init(name: $0.rawValue, support: .supported) })
    }
    func events() -> AsyncStream<EventEnvelope> { AsyncStream { continuation = $0 } }
    func send(_ envelope: CommandEnvelope) async throws -> CommandReply {
        sent.append(envelope)
        let result: CommandResult
        switch envelope.command {
        case .listProjectMcpServers:
            if holdRead { await withCheckedContinuation { held = $0 } }
            if throwRead { throw CommandError(code: "old_read_failure", message: "Old connection failed") }
            result = failure.map(CommandResult.error) ?? .mcpServers(servers)
        case .getPipelineSource(let id): result = .pipelineSource(.init(projectId: id, path: URL(fileURLWithPath: Fix.project().path).appendingPathComponent(".kaban/pipeline.yaml").path, baseVersionHash: "v1", baseSourceHash: "s1", committedContent: content, workingContent: content, worktreeSourceHash: "s1"))
        case .validatePipelineDraft(let draft): result = .pipelineDraft(.init(projectId: draft.projectId, contentHash: draft.contentHash, issues: [], baseVersionHash: draft.baseVersionHash, baseSourceHash: draft.baseSourceHash))
        default: result = .ok
        }
        return .init(commandId: envelope.commandId, seq: envelope.command.mutationScope == nil ? nil : 11, result: result)
    }
}
