import XCTest
import KabanProtocol
import KabanKit
@testable import KabanDaemonCore

final class CursorEnvironmentStoreTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_791_100_800)

    func testConfigurePersistsPublishesAndReplaysWithoutAnotherProbe() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cursor agent")
        try """
        #!/bin/sh
        printf '%s\\n' "$1" >> "\(root.path)/calls"
        case "$1" in
          --version) printf 'fixture-1.0\\n' ;;
          status) printf 'ready\\n' ;;
          --list-models) printf 'fixture-model\\tFixture Model\\n' ;;
          *) exit 99 ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path)
        let query = CommandEnvelope(command: .getCursorEnvironment)
        XCTAssertEqual(try store.execute(query).result, .cursorEnvironment(.init(executablePath: nil)))
        let envelope = CommandEnvelope(command: .configureCursor(environment: .init(executablePath: executable.path)))
        let reply = try store.execute(envelope, now: { at })
        XCTAssertEqual(reply.result, .ok)
        guard reply.result == .ok else { return }
        XCTAssertEqual(try store.execute(query).result, .cursorEnvironment(.init(executablePath: executable.path)))
        let journal = try store.journalPage(after: 0).events
        XCTAssertTrue(journal.contains { $0.commandId == envelope.commandId && $0.event == .cursorEnvironmentChanged(.init(executablePath: executable.path)) })
        guard case .models(let models) = try store.execute(.init(command: .listModels)).result else { return XCTFail("Catalog reply missing") }
        XCTAssertEqual(models.map(\.id), [ModelID(rawValue: "fixture-model")])
        XCTAssertEqual(try store.modelCatalog().map(\.id), [ModelID(rawValue: "fixture-model")])
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        let reopened = try KabanStore(path: path)
        XCTAssertEqual(try reopened.execute(envelope, now: { XCTFail("Replay read the clock"); return at }), reply)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8), calls)
        XCTAssertEqual(try reopened.execute(query).result, .cursorEnvironment(.init(executablePath: executable.path)))
        XCTAssertEqual(try reopened.getSnapshot().seq, try store.getSnapshot().seq)
    }

    func testMissingAndInvalidConfigurationHaveDifferentOutcomes() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let missing = root.appendingPathComponent("absent").path
        XCTAssertEqual(try store.execute(.init(command: .configureCursor(environment: .init(executablePath: missing))), now: { at }).result, .ok)
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentMissing)])
        let before = try store.getSnapshot()
        let invalid = CommandEnvelope(command: .configureCursor(environment: .init(executablePath: "relative/agent")))
        guard case .error(let error) = try store.execute(invalid).result else { return XCTFail("Relative executable accepted") }
        XCTAssertEqual(error.code, "cursor_environment_invalid")
        XCTAssertEqual(try store.execute(.init(command: .getCursorEnvironment)).result, .cursorEnvironment(.init(executablePath: missing)))
        XCTAssertEqual(try store.getSnapshot(), before)
    }

    func testDiscoveryPersistsOnlyPathsAndRestartUsesSavedEnvironment() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("tools with spaces")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent = bin.appendingPathComponent("cursor-agent")
        try executable(agent, text: """
        #!/bin/sh
        case "$1" in
          --version) printf 'discovered-2.0\\n' ;;
          status) [ "$JAVA_HOME" = "\(root.path)/jdk" ] || exit 8; printf 'ready\\n' ;;
          --list-models) printf 'discovered-model\\tDiscovered Model\\n' ;;
          *) exit 99 ;;
        esac
        """)
        let shell = root.appendingPathComponent("login-shell")
        try executable(shell, text: """
        #!/bin/sh
        [ "$1" = "-lc" ] || exit 5
        export PATH="\(bin.path):/usr/bin:/bin"
        export JAVA_HOME="\(root.path)/jdk"
        export CURSOR_API_KEY=DO_NOT_PERSIST_THIS
        exec /bin/sh -c "$2"
        """)
        let probe = CursorEnvironmentProbe(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], loginShell: shell.path)
        let path = root.appendingPathComponent("store.sqlite").path
        let store = try KabanStore(path: path, cursorEnvironmentProbe: probe)
        try store.initializeCursorEnvironment(at: at)
        XCTAssertEqual(try store.execute(.init(command: .getCursorEnvironment)).result, .cursorEnvironment(.init(executablePath: agent.path)))
        XCTAssertEqual(try store.runnerCheck().version, "discovered-2.0")
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [])
        let persisted = try store.database.read { try Data.fetchOne($0, sql: "SELECT payload FROM cursor_environment WHERE id = 1")! }
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("DO_NOT_PERSIST_THIS"))
        try FileManager.default.removeItem(at: shell)
        let reopened = try KabanStore(path: path, cursorEnvironmentProbe: .init(environment: ["PATH": "/bin"], loginShell: "/missing-shell"))
        try reopened.initializeCursorEnvironment(at: at.addingTimeInterval(1))
        XCTAssertEqual(try reopened.runnerCheck().version, "discovered-2.0")
        XCTAssertEqual(try reopened.runnerCheck().authOK, true)
        XCTAssertEqual(try reopened.cursorProcessEnvironment()["PATH"], bin.path + ":/usr/bin:/bin")
        XCTAssertEqual(try reopened.cursorProcessEnvironment()["JAVA_HOME"], root.path + "/jdk")
        XCTAssertEqual(try reopened.modelCatalog().map(\.id), [ModelID(rawValue: "discovered-model")])
    }

    func testStartupWithoutCLIBlocksAdmissionAndRecheckDetectsLaterInstall() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try executable(shell, text: "#!/bin/sh\nexport PATH=\"\(root.path)\"\nexec /bin/sh -c \"$2\"\n")
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path,
            cursorEnvironmentProbe: .init(environment: [:], loginShell: shell.path))
        try store.initializeCursorEnvironment(at: at)
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentMissing)])
        XCTAssertEqual(try store.runnerCheck().nextCheckAt, at.addingTimeInterval(300))
        let agent = root.appendingPathComponent("cursor-agent")
        try executable(agent, text: "#!/bin/sh\ncase \"$1\" in\n--version) echo late-1;;\nstatus) echo ready;;\n--list-models) printf 'late\\tLate Model\\n';;\nesac\n")
        _ = try store.execute(.init(command: .recheck(scope: .runner)), now: { at.addingTimeInterval(1) })
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [])
        XCTAssertEqual(try store.execute(.init(command: .getCursorEnvironment)).result, .cursorEnvironment(.init(executablePath: agent.path)))
    }

    func testProtocolMismatchAndReusedIdentityDoNotChangeConfiguration() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        var mismatched = CommandEnvelope(command: .configureCursor(environment: .init(executablePath: "/missing")))
        mismatched.protocolVersion += 1
        guard case .error(let error) = try store.execute(mismatched).result else { return XCTFail("Protocol mismatch accepted") }
        XCTAssertEqual(error.code, CommandError.protocolMismatchCode)
        XCTAssertEqual(try store.getSnapshot().seq, 0)
        let id = UUID()
        _ = try store.execute(.init(commandId: id, command: .configureCursor(environment: .init(executablePath: "/first"))))
        let before = try store.getSnapshot()
        guard case .error(let conflict) = try store.execute(.init(commandId: id, command: .getCursorEnvironment)).result else { return XCTFail("Reused identity accepted") }
        XCTAssertEqual(conflict.code, "command_id_conflict")
        XCTAssertEqual(try store.getSnapshot(), before)
    }

    func testJournalFailureRollsBackConfigurationFlagsAndReceipt() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let envelope = CommandEnvelope(command: .configureCursor(environment: .init(executablePath: root.appendingPathComponent("absent").path)))
        let before = try store.getSnapshot()
        try store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_cursor_journal BEFORE INSERT ON event BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END")
        }
        XCTAssertThrowsError(try store.execute(envelope))
        XCTAssertEqual(try store.getSnapshot(), before)
        XCTAssertEqual(try store.execute(.init(command: .getCursorEnvironment)).result, .cursorEnvironment(.init(executablePath: nil)))
        let receipts = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM wire_command WHERE id = ?", arguments: [envelope.commandId.uuidString]) }
        XCTAssertEqual(receipts, 0)
        try store.database.write { try $0.execute(sql: "DROP TRIGGER reject_cursor_journal") }
        XCTAssertEqual(try store.execute(envelope).result, .ok)
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentMissing)])
    }

    func testMigrationKeepsLegacyRunnerWithoutRequiringNewAuthField() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let legacy = try KabanStore(path: path)
        let executable = root.appendingPathComponent("old-agent").path
        let payload = try JSONSerialization.data(withJSONObject: ["executable": executable, "version": "old-version"])
        try legacy.database.write { db in
            try db.execute(sql: "UPDATE runner_check SET payload = ? WHERE id = 1", arguments: [payload])
            try db.execute(sql: "DROP TABLE cursor_environment")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'cursor_environment_v22'")
        }
        let migrated = try KabanStore(path: path)
        XCTAssertEqual(try migrated.execute(.init(command: .getCursorEnvironment)).result, .cursorEnvironment(.init(executablePath: executable)))
        XCTAssertEqual(try migrated.runnerCheck().version, "old-version")
        XCTAssertNil(try migrated.runnerCheck().authOK)
        try migrated.initializeCursorEnvironment(at: at)
        XCTAssertEqual(try migrated.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentMissing)])
        XCTAssertEqual(try migrated.execute(.init(command: .getCursorEnvironment)).result, .cursorEnvironment(.init(executablePath: executable)))
    }

    private func executable(_ url: URL, text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-cursor-environment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
