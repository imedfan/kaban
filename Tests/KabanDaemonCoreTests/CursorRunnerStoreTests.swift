import XCTest
import KabanProtocol
@testable import KabanDaemonCore

final class CursorRunnerStoreTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func testMissingAndNotExecutableRaiseRunnerUnavailable() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        try store.setRunnerExecutable(root.appendingPathComponent("missing").path)
        _ = try store.execute(.init(command: .recheck(scope: .runner)), now: { at })
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentMissing)])
        XCTAssertEqual(try store.runnerCheck().nextCheckAt, at.addingTimeInterval(300))

        let inert = root.appendingPathComponent("inert.sh")
        try "#!/bin/sh\nprintf x >> \"$(dirname \"$0\")/ran\"\n".write(to: inert, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: inert.path)
        try store.setRunnerExecutable(inert.path)
        _ = try store.execute(.init(command: .recheck(scope: .runner)), now: { at })
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentNotRunnable)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ran").path))
        XCTAssertThrowsError(try store.setRunnerExecutable("cursor-agent")) { XCTAssertEqual($0 as? StoreError, .settingsInvalid) }
    }

    func testLoggedOutRechecksEveryFiveMinutesAndOnTheButton() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        let script = root.appendingPathComponent("agent.sh")
        try """
        #!/bin/sh
        dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
        printf x >> "$dir/count"
        if [ "$1" = "--version" ]; then echo probe-1.0; exit 0; fi
        if [ "$1" = "--list-models" ]; then echo "composer-2 - Composer"; exit 0; fi
        mode=$(cat "$dir/mode" 2>/dev/null || echo out)
        if [ "$mode" = "in" ]; then echo ready; exit 0; fi
        echo "not logged in SECRET-MARKER-9f3a"
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "out".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        try store.setRunnerExecutable(script.path)

        let envelope = CommandEnvelope(command: .recheck(scope: .runner))
        _ = try store.execute(envelope, now: { at })
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [.runnerUnavailable(.agentNotLoggedIn)])
        XCTAssertEqual(try store.runnerCheck().nextCheckAt, at.addingTimeInterval(300))
        XCTAssertEqual(try store.runnerCheck().version, "probe-1.0")
        XCTAssertEqual(try store.runnerCheck().limitsNote, "composer-2 - Composer")
        XCTAssertEqual(try count(root), "xxx")
        let stored = try store.database.read { try String(data: Data.fetchOne($0, sql: "SELECT payload FROM runner_check WHERE id = 1")!, encoding: .utf8) }
        XCTAssertFalse(stored?.contains("SECRET-MARKER-9f3a") ?? true)

        let replay = try store.execute(envelope, now: { at.addingTimeInterval(50) })
        XCTAssertEqual(replay.result, .ok)
        XCTAssertEqual(try count(root), "xxx")
        _ = try store.runSchedulerPass(at: at.addingTimeInterval(299))
        // Runner is not due. The catalog is due once and calls --list-models. A space-separated line is not a catalog.
        XCTAssertEqual(try count(root), "xxxx")
        XCTAssertEqual(try store.modelCatalog(), [])

        _ = try store.execute(.init(command: .recheck(scope: .runner)), now: { at.addingTimeInterval(10) })
        XCTAssertEqual(try count(root), "xxxxxxx")
        XCTAssertEqual(try store.runnerCheck().nextCheckAt, at.addingTimeInterval(310))
        _ = try store.runSchedulerPass(at: at.addingTimeInterval(300))
        XCTAssertEqual(try count(root), "xxxxxxx")

        try "in".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        _ = try store.runSchedulerPass(at: at.addingTimeInterval(310))
        XCTAssertEqual(try count(root), "xxxxxxxxxx")
        XCTAssertEqual(try store.getSnapshot().schedulerFlags, [])
        let reopened = try KabanStore(path: root.appendingPathComponent("store.sqlite").path)
        XCTAssertEqual(try reopened.runnerCheck().version, "probe-1.0")
        XCTAssertNil(try reopened.runnerCheck().reason)
        _ = try reopened.runSchedulerPass(at: at.addingTimeInterval(609))
        XCTAssertEqual(try count(root), "xxxxxxxxxx")
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaban-cursor-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func count(_ root: URL) throws -> String {
        let url = root.appendingPathComponent("count")
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
