import Foundation
import XCTest
import KabanKit
import KabanProtocol
@testable import KabanDaemonCore

extension ProcessControlTests {
    func testConfiguredCursorUsesSeatbeltWithHostPortAndGitPolicy() throws {
        #if os(macOS)
        for preset in ["standard", "strict", "permissive"] {
            let f = try fixture(preset: preset)
            let server = try MCPBoardServer(store: f.store, now: { self.at })
            let other = try MCPBoardServer(store: f.store, now: { self.at })
            defer { server.stop(); other.stop() }
            let cli = try script(f, "seatbelt-cursor", """
            #!/bin/sh
            case "$1" in
              --version) echo fixture-28; exit 0 ;;
              status) echo '{"isAuthenticated":true}'; exit 0 ;;
              --list-models) printf 'explicit\\tExplicit\\n'; exit 0 ;;
              mcp) echo 'kaban: not loaded (needs approval)'; exit 0 ;;
            esac
            mkdir -p .be28
            echo '{"type":"system","subtype":"init","model":"Explicit"}'
            printf feature > seatbelt-feature.txt
            git status --porcelain > .be28/status 2> .be28/status.err
            echo $? > .be28/status.exit
            /usr/bin/git add seatbelt-feature.txt
            git commit -m 'Agent Seatbelt commit' > .be28/commit 2> .be28/commit.err
            echo $? > .be28/commit.exit
            printf changed > '\(f.origin)/.kaban/dev.md' 2> .be28/main.err
            echo $? > .be28/main.exit
            printf changed > .git/config 2> .be28/config.err
            echo $? > .be28/config.exit
            /usr/bin/curl --noproxy '*' -sS --max-time 3 -o .be28/progress.json -w '%{http_code}' \\
              -H "Authorization: Bearer $KABAN_RUN_TOKEN" -H 'Content-Type: application/json' \\
              -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report_progress","arguments":{"text":"Seatbelt progress"}}}' \\
              "$KABAN_MCP_URL" > .be28/progress.status 2> .be28/progress.err
            echo $? > .be28/progress.exit
            /usr/bin/curl --noproxy '*' -sS --max-time 3 'http://127.0.0.1:\(other.port)/mcp' > .be28/other 2> .be28/other.err
            echo $? > .be28/other.exit
            touch "$TMPDIR/temp-ok"
            printf '%s' "$TMPDIR" > .be28/tmpdir
            touch .be28/finished
            /bin/sleep 30
            """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli)
            try f.store.setRunnerExecutable(cli)
            let shim = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/KabanGitShim")
            f.store.attachMCPHost(.init(port: server.port, workspaceRoot: f.workspace, gitShimExecutable: shim.path))
            _ = try launch(f, "confined")
            let clone = try f.store.prepareTaskClone(taskId: "confined", at: at, workspaceRoot: f.workspace).clonePath
            _ = try f.store.runProcessPass(owner: "seatbelt", at: at, workspaceRoot: f.workspace, runner: nil, launchConfiguredCursor: true)
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: clone + "/.be28/finished"), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            func read(_ name: String) throws -> String {
                try String(contentsOfFile: clone + "/.be28/" + name, encoding: .utf8).trimmingCharacters(in: .newlines)
            }
            let record = try XCTUnwrap(f.store.agentProcesses().first)
            let stderr = (try? String(contentsOfFile: record.stderrPath, encoding: .utf8)) ?? ""
            XCTAssertTrue(FileManager.default.fileExists(atPath: clone + "/.be28/finished"), stderr)
            XCTAssertEqual(try read("status.exit"), "0", (try? read("status.err")) ?? stderr)
            XCTAssertEqual(try read("progress.exit"), "0", (try? read("progress.err")) ?? stderr)
            XCTAssertEqual(try read("progress.status"), "200")
            XCTAssertEqual(try f.store.getTaskDetail("confined").feed.last { $0.kind == "progress" }?.text, "Seatbelt progress")
            XCTAssertNotEqual(try read("other.exit"), "0")
            XCTAssertNotEqual(try read("main.exit"), "0")
            XCTAssertNotEqual(try read("config.exit"), "0")
            XCTAssertEqual(try String(contentsOfFile: f.origin + "/.kaban/dev.md", encoding: .utf8), "skill")
            let temp = try read("tmpdir")
            XCTAssertTrue(temp.hasPrefix(f.workspace + "/mcp-homes/"), temp)
            XCTAssertTrue(FileManager.default.fileExists(atPath: temp + "/temp-ok"))
            if preset == "strict" {
                XCTAssertEqual(try read("commit.exit"), "1")
                XCTAssertTrue(try read("commit.err").contains(GitCheck.deniedMessage))
                XCTAssertEqual(try f.store.getTaskDetail("confined").gitDenials.last?.denial.argv, ["commit", "-m", "Agent Seatbelt commit"])
            } else {
                XCTAssertEqual(try read("commit.exit"), "0", (try? read("commit.err")) ?? stderr)
                XCTAssertEqual(try text(clone, ["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "Agent Seatbelt commit")
            }
        }
        #else
        throw XCTSkip("Production Seatbelt is a macOS boundary")
        #endif
    }
}
