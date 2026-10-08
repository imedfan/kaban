import Foundation
import XCTest
import KabanKit
import KabanProtocol
import KabanBoardCore
@testable import KabanDaemonCore

extension PipelineLifecycleTests {
    func testMCPWireCatalogIsFreshSecretFreeAndAllowlistIsDurableProjectLocal() throws {
        let f = try fixture(content: yaml), other = try fixture(content: yaml)
        let personal = f.root.appendingPathComponent("personal/mcp.json")
        let store = try KabanStore(path: f.database, personalMCPConfig: personal)
        let projectFile = f.repo.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let projectJSON = "{\"mcpServers\":{\"external\":{\"url\":\"https://example.test/private?token=secret\",\"headers\":{\"Authorization\":\"private\"}},\"shared\":{\"command\":\"private-command\"}}}"
        let personalJSON = "{\"mcpServers\":{\"personal\":{\"command\":\"private-command\",\"args\":[\"secret\"]},\"shared\":{\"url\":\"https://personal.test\"}}}"
        try Data(projectJSON.utf8).write(to: projectFile); try Data(personalJSON.utf8).write(to: personal)
        let service = DaemonService(store: store)
        let query = CommandEnvelope(command: .listProjectMcpServers(projectId: f.project))
        let catalogReply = try store.execute(query)
        guard case .mcpServers(let catalog) = catalogReply.result else { return XCTFail("\(catalogReply)") }
        XCTAssertEqual(catalog, [.init(name: "external", source: .project), .init(name: "shared", source: .project), .init(name: "personal", source: .personal), .init(name: "shared", source: .personal)])
        let wire = String(decoding: service.handle(data: try DaemonWire.encode(DaemonRequest(.command(query)))), as: UTF8.self)
        for secret in ["secret", "private-command", "Authorization", "https://"] { XCTAssertFalse(wire.contains(secret)) }
        XCTAssertEqual(DaemonService.capabilities.commands.first { $0.name == "setProjectMcpAllowlist" }?.support, .supported)
        let before = try store.getSnapshot()
        let command = CommandEnvelope(command: .setProjectMcpAllowlist(projectId: f.project, servers: [.init(name: "external", source: .project), .init(name: "shared", source: .personal)]))
        let reply = try store.execute(command)
        XCTAssertEqual(reply.result, .ok)
        var projection = BoardProjection(snapshot: before)
        for event in try store.events(after: before.seq) { _ = projection.apply(event) }
        XCTAssertEqual(projection.projects[f.project]?.mcpAllowlist, ["kaban", "external", "shared"])
        XCTAssertEqual(projection.pipelines[f.project]?.stages.first { $0.id == "dev" }?.effectiveMcp, ["kaban", "external"])
        XCTAssertFalse(projection.pipelines[f.project]?.issues.contains { $0.code == "mcp_not_allowlisted" } ?? true)
        XCTAssertEqual(try other.store.getSnapshot().projects.first?.mcpAllowlist, ["kaban"])
        XCTAssertEqual(try Data(contentsOf: personal), Data(personalJSON.utf8))
        XCTAssertEqual(try Data(contentsOf: projectFile), Data(projectJSON.utf8))
        let reopened = try KabanStore(path: f.database, personalMCPConfig: personal)
        XCTAssertEqual(try reopened.getSnapshot().projects.first?.mcpAllowlist, ["kaban", "external", "shared"])
        let seq = try reopened.getSnapshot().seq
        XCTAssertEqual(try reopened.execute(command), reply); XCTAssertEqual(try reopened.getSnapshot().seq, seq)
        var conflict = command; conflict.command = .setProjectMcpAllowlist(projectId: f.project, servers: [])
        XCTAssertEqual(try refusal(reopened.execute(conflict)).code, "command_id_conflict")
        XCTAssertEqual(try reopened.execute(.init(command: .setProjectMcpAllowlist(projectId: f.project, servers: []))).result, .ok)
        let after = try reopened.getSnapshot()
        XCTAssertEqual(after.projects.first?.mcpAllowlist, ["kaban"])
        XCTAssertEqual(after.pipelines.first?.stages.first { $0.id == "dev" }?.mcp, ["kaban", "external"])
        XCTAssertEqual(after.pipelines.first?.stages.first { $0.id == "dev" }?.effectiveMcp, ["kaban"])
        XCTAssertTrue(after.pipelines.first?.isValid == true)
        XCTAssertTrue(after.pipelines.first?.issues.contains { $0.code == "mcp_not_allowlisted" && $0.severity == .warning } == true)
        try Data("{broken-secret".utf8).write(to: personal)
        let error = try refusal(reopened.execute(query))
        XCTAssertEqual(error.code, "mcp_config_unreadable"); XCTAssertEqual(error.params, ["source": "personal"])
        XCTAssertFalse(error.message.contains("broken-secret"))
        try Data("{\"mcpServers\":{}}".utf8).write(to: personal)
        guard case .mcpServers(let fresh) = try reopened.execute(query).result else { return XCTFail("Query was cached") }
        XCTAssertEqual(fresh.count, 2)
        let stale = try reopened.execute(.init(command: .setProjectMcpAllowlist(projectId: f.project, servers: [.init(name: "personal", source: .personal)])))
        XCTAssertEqual(try refusal(stale).code, "mcp_catalog_changed")
        XCTAssertEqual(try reopened.getSnapshot().projects.first?.mcpAllowlist, ["kaban"])
        try FileManager.default.removeItem(at: personal)
        guard case .mcpServers(let missingPersonal) = try reopened.execute(query).result else { return XCTFail("Missing config was treated as unreadable") }
        XCTAssertEqual(missingPersonal.count, 2)
        try FileManager.default.removeItem(at: projectFile)
        try FileManager.default.createSymbolicLink(at: projectFile, withDestinationURL: personal)
        XCTAssertEqual(try refusal(reopened.execute(query)).code, "mcp_config_unreadable")
    }

    func testMCPDiagnosticSurvivesPipelineRecheckUntilFreshPreflight() throws {
        let f = try fixture(content: yaml), before = try f.store.getSnapshot()
        try create(f)
        _ = try f.store.applyMCPPreflight(taskId: "task", definitions: [], boardURL: "http://127.0.0.1:9/mcp", listOutput: "kaban\tboard\nrogue\tpersonal\n", listExit: 0, at: at)
        let blocked = try f.store.getSnapshot()
        XCTAssertEqual(blocked.projects.first?.mcpIssue, .init(kind: .unexpected, name: "rogue"))
        XCTAssertTrue(blocked.schedulerFlags.contains { if case .projectUnavailable(f.project, .mcpUnexpected, _) = $0 { return true }; return false })
        var projection = BoardProjection(snapshot: before)
        for event in try f.store.events(after: before.seq) { _ = projection.apply(event) }
        XCTAssertEqual(projection.projects[f.project]?.mcpIssue, blocked.projects.first?.mcpIssue)
        XCTAssertEqual(try f.store.execute(.init(command: .recheck(scope: .project(projectId: f.project)))).result, .ok)
        XCTAssertEqual(try f.store.getSnapshot().projects.first?.mcpIssue, .init(kind: .unexpected, name: "rogue"))
        XCTAssertTrue(try f.store.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(f.project, .mcpUnexpected, _) = $0 { return true }; return false })
        let reopened = try KabanStore(path: f.database)
        XCTAssertEqual(try reopened.getSnapshot().projects.first?.mcpIssue?.name, "rogue")
        _ = try reopened.applyMCPPreflight(taskId: "task", definitions: [], boardURL: "http://127.0.0.1:9/mcp", listOutput: "kaban\tboard\n", listExit: 0, at: at)
        XCTAssertNil(try reopened.getSnapshot().projects.first?.mcpIssue)
        XCTAssertFalse(try reopened.getSnapshot().schedulerFlags.contains { if case .projectUnavailable(f.project, .mcpUnexpected, _) = $0 { return true }; return false })
    }
}
