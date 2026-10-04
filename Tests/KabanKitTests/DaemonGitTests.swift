import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
import KabanProtocol
@testable import KabanKit

/// `realpath(3)`. `URL.resolvingSymlinksInPath` / `standardizingPath` strip `/private` on Darwin and must not be used.
private func posixRealpath(_ path: String) -> String {
    guard let resolved = path.withCString({ realpath($0, nil) }) else { return path }
    let copy = String(cString: resolved)
    free(resolved)
    return copy
}

/// Daemon git calls in a clone: hooks and fsmonitor disabled, whitelisted environment without inherited `GIT_*`,
/// no global/system config, explicit author, no editor, no prompt, merge `--no-edit` (arch. v0.11.19 §8.2).
/// Real git, skipped without it.
final class DaemonGitTests: XCTestCase {
    static let id = GitIdentity(name: "Kaban Daemon", email: "daemon@kaban.invalid")
    static var idArgs: [String] { ["-c", "user.name=Kaban Daemon", "-c", "user.email=daemon@kaban.invalid"] }

    func testArgumentsAlwaysCarryHardening() throws {
        XCTAssertEqual(try DaemonGit.arguments(["merge", "--no-ff", "kaban/t-1"], in: "/clones/t-1", identity: Self.id),
                       ["-C", "/clones/t-1", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + Self.idArgs
                        + ["merge", "--no-edit", "--no-ff", "kaban/t-1"])
        XCTAssertEqual(try DaemonGit.arguments(["status"]), ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "status"])
        XCTAssertEqual(try DaemonGit.argv(["status"]).first, DaemonGit.executable)
        XCTAssertEqual(DaemonGit.hardeningConfig, ["core.hooksPath=/dev/null", "core.fsmonitor=false"])
        // Global options are reserved for the builder (a caller's `-c core.hooksPath=…` must not override it).
        XCTAssertThrowsError(try DaemonGit.arguments(["-c", "core.hooksPath=.git/hooks", "merge"])) {
            XCTAssertEqual($0 as? DaemonGit.BuildError, .globalOptionNotAllowed("-c"))
        }
        XCTAssertThrowsError(try DaemonGit.arguments(["-C", "/elsewhere", "status"])) {
            XCTAssertEqual($0 as? DaemonGit.BuildError, .globalOptionNotAllowed("-C"))
        }
        XCTAssertThrowsError(try DaemonGit.arguments(["--git-dir=/x", "status"]))
        XCTAssertThrowsError(try DaemonGit.arguments(["--git-dir", "/x", "status"]))
        XCTAssertThrowsError(try DaemonGit.arguments([])) { XCTAssertEqual($0 as? DaemonGit.BuildError, .emptyCommand) }
        // Subcommand options with the same letters are not global options.
        XCTAssertNoThrow(try DaemonGit.arguments(["switch", "-c", "topic"]))
        XCTAssertNoThrow(try DaemonGit.arguments(["commit", "-C", "HEAD"], identity: Self.id))
        XCTAssertNoThrow(try DaemonGit.arguments(["rev-parse", "--git-dir"]))
    }

    func testEnvironmentNeverWaitsForInput() {
        XCTAssertEqual(DaemonGit.environment, ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0",
                                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        XCTAssertEqual(DaemonGit.inheritedWhitelist, ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG"])
        XCTAssertEqual(DaemonGit.inheritedPrefixes, ["LC_"])
        XCTAssertTrue(DaemonGit.isInherited("LC_MESSAGES")); XCTAssertFalse(DaemonGit.isInherited("GIT_EDITOR"))
        XCTAssertFalse(DaemonGit.isInherited("LCX")); XCTAssertFalse(DaemonGit.isInherited("SSH_ASKPASS"))
        let merged = DaemonGit.environment(merging: ["PATH": "/usr/bin", "GIT_EDITOR": "vim", "GIT_SEQUENCE_EDITOR": "vim",
                                                     "GIT_TERMINAL_PROMPT": "1", "GIT_CONFIG_GLOBAL": "/home/u/.gitconfig",
                                                     "GIT_CONFIG_NOSYSTEM": "0"])
        XCTAssertEqual(merged, ["PATH": "/usr/bin", "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0",
                                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                       "daemon values override the base")
        XCTAssertEqual(DaemonGit.environment(merging: [:]), DaemonGit.environment)
        XCTAssertFalse(DaemonGit.processEnvironment.keys.contains { $0.hasPrefix("GIT_") && DaemonGit.environment[$0] == nil })
    }

    /// (a) Built from scratch by whitelist: no inherited `GIT_*`, no other non-whitelisted variable.
    func testEnvironmentDropsEverythingNotWhitelisted() {
        let base = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/artem", "TMPDIR": "/tmp/x", "USER": "artem", "LOGNAME": "artem",
            "LANG": "ru_RU.UTF-8", "LC_ALL": "C", "LC_CTYPE": "UTF-8", "LC_MESSAGES": "C",
            "GIT_DIR": "/elsewhere/.git", "GIT_WORK_TREE": "/elsewhere", "GIT_INDEX_FILE": "/tmp/idx",
            "GIT_CONFIG_PARAMETERS": "'core.hooksPath'='/tmp/hooks'", "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.hooksPath", "GIT_CONFIG_VALUE_0": "/tmp/hooks", "GIT_CONFIG_GLOBAL": "/tmp/g",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_EXEC_PATH": "/tmp/exec", "GIT_SSH_COMMAND": "evil", "GIT_SSH": "evil",
            "GIT_EXTERNAL_DIFF": "evil", "GIT_ASKPASS": "evil", "GIT_PAGER": "evil", "GIT_AUTHOR_NAME": "x",
            "SSH_ASKPASS": "evil", "EDITOR": "vim", "VISUAL": "vim", "XDG_CONFIG_HOME": "/tmp/xdg", "FOO": "bar",
        ]
        let env = DaemonGit.environment(merging: base)
        XCTAssertEqual(env, [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/artem", "TMPDIR": "/tmp/x", "USER": "artem", "LOGNAME": "artem",
            "LANG": "ru_RU.UTF-8", "LC_ALL": "C", "LC_CTYPE": "UTF-8", "LC_MESSAGES": "C",
            "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ])
        XCTAssertEqual(Set(env.keys.filter { $0.hasPrefix("GIT_") }),
                       ["GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_TERMINAL_PROMPT", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"])
        for k in ["GIT_DIR", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_SSH_COMMAND",
                  "GIT_EXTERNAL_DIFF", "SSH_ASKPASS", "FOO"] {
            XCTAssertNil(env[k], k)
        }
    }

    func testMergeAlwaysHasNoEdit() throws {
        let h = DaemonGit.hardeningArguments + Self.idArgs
        XCTAssertEqual(try DaemonGit.merge(["--no-ff", "kaban/t-1"], in: "/c", identity: Self.id), ["-C", "/c"] + h + ["merge", "--no-edit", "--no-ff", "kaban/t-1"])
        XCTAssertEqual(try DaemonGit.merge(["--no-edit", "x"], identity: Self.id), h + ["merge", "--no-edit", "x"], "not duplicated")
        XCTAssertEqual(try DaemonGit.merge(["--abort"], identity: Self.id), h + ["merge", "--no-edit", "--abort"])
        XCTAssertEqual(try DaemonGit.merge(["--no-ff", "x"], identity: Self.id), try DaemonGit.arguments(["merge", "--no-ff", "x"], identity: Self.id))
        for edit in ["--edit", "-e"] {
            XCTAssertThrowsError(try DaemonGit.merge([edit, "x"], identity: Self.id)) { XCTAssertEqual($0 as? DaemonGit.BuildError, .editNotAllowed(edit)) }
        }
        // Only merge is rewritten.
        XCTAssertEqual(try DaemonGit.arguments(["commit", "-m", "x"], identity: Self.id), h + ["commit", "-m", "x"])
    }

    /// v0.11.18: the author is explicit; commit-writing commands without it fail fast instead of guessing.
    func testIdentityIsExplicitAndRequiredForCommits() throws {
        for sub in ["commit", "merge", "rebase", "cherry-pick", "revert", "am", "stash"] {
            XCTAssertThrowsError(try DaemonGit.arguments([sub]), sub) { XCTAssertEqual($0 as? DaemonGit.BuildError, .identityRequired(sub)) }
        }
        XCTAssertEqual(DaemonGit.commitWritingCommands, ["commit", "merge", "rebase", "cherry-pick", "revert", "am", "stash"])
        // Read-only/plumbing calls do not need it, but still get it when supplied.
        XCTAssertEqual(try DaemonGit.arguments(["status"]), DaemonGit.hardeningArguments + ["status"])
        XCTAssertEqual(try DaemonGit.arguments(["status"], identity: Self.id), DaemonGit.hardeningArguments + Self.idArgs + ["status"])
        // The protocol's GitIdentity is a plain value, so DaemonGit validates it on every call: no empty fields, no
        // line breaks/NUL (they would corrupt the -c value); spaces trimmed.
        let cases: [(GitIdentity, GitIdentityRequired)] = [
            (GitIdentity(name: "", email: "a@b"), GitIdentityRequired(missing: [.name], found: .init(email: "a@b"))),
            (GitIdentity(name: "A", email: "  "), GitIdentityRequired(missing: [.email], found: .init(name: "A"))),
            (GitIdentity(name: "A\nB", email: "a@b"), GitIdentityRequired(invalid: [.name], found: .init(email: "a@b"))),
            (GitIdentity(name: "A", email: "a@b\r"), GitIdentityRequired(invalid: [.email], found: .init(name: "A"))),
            (GitIdentity(name: "A\0", email: "a@b"), GitIdentityRequired(invalid: [.name], found: .init(email: "a@b"))),
        ]
        for (bad, expected) in cases {
            XCTAssertThrowsError(try bad.validated()) { XCTAssertEqual($0 as? GitIdentityRequired, expected) }
            for sub in ["commit", "status"] {
                XCTAssertThrowsError(try DaemonGit.arguments([sub], identity: bad)) {
                    XCTAssertEqual($0 as? DaemonGit.BuildError, .invalidIdentity(expected))
                }
            }
        }
        let spaced = GitIdentity(name: " Artem Palkin ", email: "artem@example.com\t")
        XCTAssertEqual(try spaced.validated(), GitIdentity(name: "Artem Palkin", email: "artem@example.com"))
        XCTAssertEqual(try DaemonGit.arguments(["commit"], identity: spaced),
                       DaemonGit.hardeningArguments + ["-c", "user.name=Artem Palkin", "-c", "user.email=artem@example.com", "commit"])
        // Caller-supplied global -c stays rejected even with an identity.
        XCTAssertThrowsError(try DaemonGit.arguments(["-c", "user.name=evil", "commit"], identity: Self.id))
    }

    // MARK: Real git

    struct Sandbox {
        let root: URL
        /// Path before `realpath(3)`. On macOS this is `/var/folders/...` while `root` is `/private/var/folders/...`.
        let requestedPath: String
        var marker: URL { root.appendingPathComponent("marker.txt") }
        var markerLines: [String] {
            ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        static func make() throws -> Sandbox {
            guard FileManager.default.isExecutableFile(atPath: DaemonGit.executable) else {
                throw XCTSkip("git not found at \(DaemonGit.executable)")
            }
            let requested = FileManager.default.temporaryDirectory
                .appendingPathComponent("kaban-daemongit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
            // Canonicalize before any repo exists. Git matches includeIf gitdir: against the resolved gitdir.
            let canonical = posixRealpath(requested.path)
            let root = URL(fileURLWithPath: canonical, isDirectory: true)
            return Sandbox(root: root, requestedPath: requested.path)
        }

        /// Minimal runner for tests: /usr/bin/git with an isolated environment (no system/global config).
        /// Base environment of the "daemon process" (no system/global config). Extra keys, e.g. a hostile `GIT_EDITOR`,
        /// can be added per test; daemon calls get `DaemonGit.environment(merging:)` on top.
        var baseEnvironment: [String: String] {
            ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
             "GIT_AUTHOR_NAME": "Kaban", "GIT_AUTHOR_EMAIL": "kaban@example.invalid",
             "GIT_COMMITTER_NAME": "Kaban", "GIT_COMMITTER_EMAIL": "kaban@example.invalid"]
        }

        @discardableResult
        func git(_ args: [String], env: [String: String]? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> String {
            let (status, text) = try run(args, env: env)
            XCTAssertEqual(status, 0, "git \(args.joined(separator: " ")): \(text)", file: file, line: line)
            return text
        }

        /// Runs git without asserting the exit status; `stdin` is fed to the process (else /dev/null).
        func run(_ args: [String], env: [String: String]? = nil, stdin: String? = nil) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: DaemonGit.executable)
            p.arguments = args
            p.currentDirectoryURL = root
            p.environment = env ?? baseEnvironment
            let input = Pipe()
            p.standardInput = stdin == nil ? FileHandle.nullDevice : input
            let out = Pipe()
            p.standardOutput = out; p.standardError = out
            try p.run()
            if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)); try input.fileHandleForWriting.close() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        func plain(_ cmd: [String], in dir: String) throws { try git(["-C", dir] + cmd) }
        func daemon(_ cmd: [String], in dir: String) throws {
            try git(try DaemonGit.arguments(cmd, in: dir, identity: DaemonGitTests.id), env: DaemonGit.environment(merging: baseEnvironment))
        }

        func write(_ text: String, to path: String, executable: Bool = false) throws {
            let url = root.appendingPathComponent(path)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }

        /// origin with one commit on `main`, and a clone `name` with planted hooks writing to the marker.
        func cloneWithHooks(_ name: String) throws -> String {
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("origin").path) {
                try git(["init", "-q", "-b", "main", "origin"])
                try write("a\n", to: "origin/a.txt")
                try plain(["add", "a.txt"], in: "origin"); try plain(["commit", "-q", "-m", "init"], in: "origin")
            }
            try git(["clone", "-q", "origin", name])
            // For the plain-git controls; DaemonGit passes the explicit identity (`-c user.name/email`), which wins.
            try plain(["config", "user.name", "Kaban"], in: name); try plain(["config", "user.email", "kaban@example.invalid"], in: name)
            for hook in ["pre-commit", "pre-merge-commit", "post-merge", "post-checkout"] {
                try write("#!/bin/sh\necho \(name) \(hook) >> '\(marker.path)'\n", to: "\(name)/.git/hooks/\(hook)", executable: true)
            }
            return name
        }

        /// Branch, commit, checkout and a real merge commit, each through `run`.
        func workflow(_ dir: String, _ run: ([String], String) throws -> Void) throws {
            try run(["checkout", "-q", "-b", "feature"], dir)
            try write("b\n", to: "\(dir)/b.txt")
            try run(["add", "b.txt"], dir)
            try run(["commit", "-q", "-m", "feature"], dir)
            try run(["checkout", "-q", "main"], dir)
            try write("c\n", to: "\(dir)/c.txt")
            try run(["add", "c.txt"], dir)
            try run(["commit", "-q", "-m", "main side"], dir)
            try run(["merge", "-q", "--no-ff", "-m", "merge feature", "feature"], dir)
        }
    }

    func testPlantedHooksDoNotRunThroughDaemonGit() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let hardened = try s.cloneWithHooks("hardened")
        try s.workflow(hardened, s.daemon)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.marker.path), "hooks ran: \(s.markerLines)")
        // The merge really happened.
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("hardened/b.txt").path))

        // Control: the same workflow with plain git runs every planted hook, so the test is real.
        let plain = try s.cloneWithHooks("plain")
        try s.workflow(plain, s.plain)
        let ran = Set(s.markerLines)
        for hook in ["pre-commit", "pre-merge-commit", "post-merge", "post-checkout"] {
            XCTAssertTrue(ran.contains("plain \(hook)"), "\(hook) did not run with plain git: \(s.markerLines)")
        }
        XCTAssertFalse(s.markerLines.contains { $0.hasPrefix("hardened") })
    }

    func testFSMonitorFromConfigDoesNotRunThroughDaemonGit() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let dir = try s.cloneWithHooks("fsm")
        try s.write("#!/bin/sh\necho fsmonitor >> '\(s.marker.path)'\n", to: "fsmonitor.sh", executable: true)
        try s.plain(["config", "core.fsmonitor", s.root.appendingPathComponent("fsmonitor.sh").path], in: dir)
        try s.write("changed\n", to: "\(dir)/a.txt")

        try s.daemon(["status", "--porcelain"], in: dir)
        try s.daemon(["diff", "--stat"], in: dir)
        XCTAssertFalse(s.markerLines.contains("fsmonitor"), "fsmonitor ran through DaemonGit: \(s.markerLines)")

        try s.plain(["status", "--porcelain"], in: dir)
        XCTAssertTrue(s.markerLines.contains("fsmonitor"), "control: plain git should run the configured fsmonitor")
    }

    /// `GIT_EDITOR=true` beats `core.editor` from the clone and a hostile `GIT_EDITOR` in the base env; merge needs no editor.
    func testEditorNeverRunsThroughDaemonGit() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let dir = try s.cloneWithHooks("editor")
        let editor = s.root.appendingPathComponent("editor.sh").path
        try s.write("#!/bin/sh\necho editor >> '\(s.marker.path)'\nexit 0\n", to: "editor.sh", executable: true)
        try s.plain(["config", "core.editor", editor], in: dir)
        try s.plain(["checkout", "-q", "-b", "feature"], in: dir)
        try s.write("b\n", to: "\(dir)/b.txt")
        try s.plain(["add", "b.txt"], in: dir); try s.plain(["commit", "-q", "-m", "feature"], in: dir)
        try s.plain(["checkout", "-q", "main"], in: dir)
        try? FileManager.default.removeItem(at: s.marker)   // hooks from setup

        var hostile = s.baseEnvironment
        hostile["GIT_EDITOR"] = editor; hostile["GIT_TERMINAL_PROMPT"] = "1"
        let env = DaemonGit.environment(merging: hostile)
        // A merge commit without -m: --no-edit takes the default message, no editor.
        try s.git(try DaemonGit.merge(["--no-ff", "feature"], in: dir, identity: Self.id), env: env)
        let parents = try s.git(try DaemonGit.arguments(["rev-list", "--parents", "-1", "HEAD"], in: dir), env: env)
        XCTAssertEqual(parents.split(separator: " ").count, 3, "HEAD is a merge commit: \(parents)")
        // commit --amend would open the editor; GIT_EDITOR=true keeps the message.
        try s.git(try DaemonGit.arguments(["commit", "--amend"], in: dir, identity: Self.id), env: env)
        XCTAssertFalse(s.markerLines.contains("editor"), "editor ran through DaemonGit: \(s.markerLines)")

        // Control: plain git with the same base env runs the editor, so the test is real.
        try s.git(["-C", dir, "commit", "--amend"], env: hostile)
        XCTAssertTrue(s.markerLines.contains("editor"), "control: plain git should run the editor")
    }

    /// (b) Inherited `GIT_CONFIG_COUNT`/`KEY_0`/`VALUE_0` (a hooks dir with a marker hook) and `GIT_DIR` (another repo)
    /// do not reach a daemon commit: it lands in the clone and no hook fires.
    func testInheritedGitVariablesDoNotReachDaemonGit() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let dir = try s.cloneWithHooks("clone")
        let other = try s.cloneWithHooks("other")
        try FileManager.default.createDirectory(at: s.root.appendingPathComponent("evil-hooks"), withIntermediateDirectories: true)
        try s.write("#!/bin/sh\necho evil-hook >> '\(s.marker.path)'\n", to: "evil-hooks/pre-commit", executable: true)
        try? FileManager.default.removeItem(at: s.marker)
        func head(_ repo: String) throws -> String {
            try s.git(["-C", repo, "log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let otherHead = try head(other)

        var hostile = s.baseEnvironment
        hostile["GIT_CONFIG_COUNT"] = "1"
        hostile["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        hostile["GIT_CONFIG_VALUE_0"] = s.root.appendingPathComponent("evil-hooks").path
        hostile["GIT_DIR"] = s.root.appendingPathComponent("other/.git").path

        try s.git(try DaemonGit.arguments(["commit", "-q", "--allow-empty", "-m", "daemon commit"], in: dir, identity: Self.id),
                  env: DaemonGit.environment(merging: hostile))
        XCTAssertEqual(try head(dir), "daemon commit", "commit landed in the clone")
        XCTAssertEqual(try head(other), otherHead, "GIT_DIR was ignored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.marker.path), "a hook ran: \(s.markerLines)")

        // Control: plain git with the same inherited variables commits into the other repo and runs the injected hook.
        try s.git(["-C", dir, "commit", "-q", "--allow-empty", "-m", "plain commit"], env: hostile)
        XCTAssertEqual(try head(other), "plain commit", "control: GIT_DIR redirects plain git")
        XCTAssertTrue(s.markerLines.contains("evil-hook"), "control: injected hooksPath fires with plain git")
    }

    /// (c) `rebase -i` with `sequence.editor` and `core.editor` marker scripts in the clone completes without running them.
    func testInteractiveRebaseNeverRunsEditors() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let dir = try s.cloneWithHooks("rebase")
        try s.write("#!/bin/sh\necho sequence-editor >> '\(s.marker.path)'\nexit 0\n", to: "seq.sh", executable: true)
        try s.write("#!/bin/sh\necho core-editor >> '\(s.marker.path)'\nexit 0\n", to: "ed.sh", executable: true)
        try s.plain(["config", "sequence.editor", s.root.appendingPathComponent("seq.sh").path], in: dir)
        try s.plain(["config", "core.editor", s.root.appendingPathComponent("ed.sh").path], in: dir)
        try s.write("b\n", to: "\(dir)/b.txt")
        try s.plain(["add", "b.txt"], in: dir); try s.plain(["commit", "-q", "-m", "second"], in: dir)
        try? FileManager.default.removeItem(at: s.marker)

        var hostile = s.baseEnvironment
        hostile["GIT_SEQUENCE_EDITOR"] = s.root.appendingPathComponent("seq.sh").path
        try s.git(try DaemonGit.arguments(["rebase", "-q", "-i", "HEAD~1"], in: dir, identity: Self.id), env: DaemonGit.environment(merging: hostile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.marker.path), "an editor ran: \(s.markerLines)")
        let status = try s.git(try DaemonGit.arguments(["status", "--porcelain=v2", "--branch"], in: dir), env: DaemonGit.environment(merging: hostile))
        XCTAssertFalse(status.contains("rebase"), "rebase finished: \(status)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent("\(dir)/.git/rebase-merge").path))

        // Control: plain git runs the configured sequence editor.
        try s.git(["-C", dir, "rebase", "-q", "-i", "HEAD~1"])
        XCTAssertTrue(s.markerLines.contains("sequence-editor"), "control: plain git should run sequence.editor")
    }

    /// v0.11.18: a hostile `~/.gitconfig` (via `HOME`) — pager, alias, includeIf, credential.helper, hooksPath, identity —
    /// does not affect DaemonGit; the commit author/committer are exactly the passed identity. Plain git picks it all up.
    func testHostileGlobalConfigDoesNotReachDaemonGit() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let dir = try s.cloneWithHooks("clone")
        // The clone's own identity would otherwise win over nothing; drop it so the comparison is about global config.
        try s.plain(["config", "--unset", "user.name"], in: dir); try s.plain(["config", "--unset", "user.email"], in: dir)
        let home = s.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        let m = s.marker.path
        try s.write("#!/bin/sh\necho pager >> '\(m)'\ncat\n", to: "home/pager.sh", executable: true)
        try s.write("#!/bin/sh\necho credential >> '\(m)'\necho username=x\necho password=y\n", to: "home/cred.sh", executable: true)
        try s.write("#!/bin/sh\necho global-hook >> '\(m)'\n", to: "home/hooks/pre-commit", executable: true)
        try s.write("[user]\n\tname = Included Evil\n\temail = included@evil.invalid\n", to: "home/included.gitconfig")
        // Both spellings: git matches the resolved gitdir (`/private/var/...`), the raw temp path is `/var/...`.
        var seenGitdirs = Set<String>()
        let includeIf = [s.requestedPath, s.root.path].compactMap { path -> String? in
            let dir = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard seenGitdirs.insert(dir).inserted else { return nil }
            return "[includeIf \"gitdir:\(dir)/\"]\n\tpath = \(home.path)/included.gitconfig"
        }.joined(separator: "\n")
        try s.write("""
        [user]
        \tname = Evil Global
        \temail = evil@global.invalid
        [core]
        \tpager = \(home.path)/pager.sh
        \thooksPath = \(home.path)/hooks
        [alias]
        \tst = "!echo alias >> '\(m)'"
        [credential]
        \thelper = \(home.path)/cred.sh
        \(includeIf)
        """, to: "home/.gitconfig")
        try? FileManager.default.removeItem(at: s.marker)

        // A "daemon process" whose HOME points at the hostile config and which inherits nothing else git-specific.
        let base: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        let daemonEnv = DaemonGit.environment(merging: base)
        let credentialInput = "protocol=https\nhost=example.invalid\n\n"

        // Through DaemonGit: none of the global keys is visible at all …
        for key in ["user.name", "core.pager", "alias.st", "credential.helper"] {
            let (status, out) = try s.run(try DaemonGit.arguments(["config", "--get", key], in: dir), env: daemonEnv)
            XCTAssertEqual(status, 1, "\(key) leaked into DaemonGit: \(out)")
        }
        // … the commit uses exactly the passed identity, no hook runs …
        try s.git(try DaemonGit.arguments(["commit", "-q", "--allow-empty", "-m", "daemon"], in: dir, identity: Self.id), env: daemonEnv)
        let who = try s.git(try DaemonGit.arguments(["log", "-1", "--format=%an|%ae|%cn|%ce"], in: dir), env: daemonEnv)
        XCTAssertEqual(who.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Kaban Daemon|daemon@kaban.invalid|Kaban Daemon|daemon@kaban.invalid")
        // … the alias does not exist and the credential helper is not called.
        let (aliasStatus, _) = try s.run(try DaemonGit.arguments(["st"], in: dir), env: daemonEnv)
        XCTAssertNotEqual(aliasStatus, 0)
        _ = try s.run(try DaemonGit.arguments(["credential", "fill"], in: dir), env: daemonEnv, stdin: credentialInput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.marker.path), "hostile global config ran: \(s.markerLines)")

        // Control: plain git with the same HOME picks everything up.
        let plainEnv = base
        XCTAssertEqual(try s.git(["-C", dir, "config", "--get", "core.pager"], env: plainEnv).trimmingCharacters(in: .whitespacesAndNewlines),
                       "\(home.path)/pager.sh")
        try s.git(["-C", dir, "commit", "-q", "--allow-empty", "-m", "plain"], env: plainEnv)
        let plainWho = try s.git(["-C", dir, "log", "-1", "--format=%an|%ae"], env: plainEnv)
        XCTAssertEqual(plainWho.trimmingCharacters(in: .whitespacesAndNewlines), "Included Evil|included@evil.invalid", "includeIf applies")
        try s.git(["-C", dir, "st"], env: plainEnv)
        _ = try s.run(["-C", dir, "credential", "fill"], env: plainEnv, stdin: credentialInput)
        let ran = Set(s.markerLines)
        for marker in ["global-hook", "alias", "credential"] { XCTAssertTrue(ran.contains(marker), "control: \(marker) did not run: \(s.markerLines)") }
    }

    // MARK: Project identity (arch. v0.11.21 §8.2, spec v0.8.22 UC-01)

    /// Pure resolver used at `addProject`: explicit wins (and must be valid), else the repository's, else identity_required.
    func testResolveForProject() throws {
        let explicit = GitIdentity(name: "Artem Palkin", email: "artem@example.com")
        let repo = GitIdentityFields(name: "Repo User", email: "repo@example.com")
        var reads = 0
        func fromRepo(_ v: GitIdentityFields) -> GitIdentityFields { reads += 1; return v }

        XCTAssertEqual(try GitIdentity.resolveForProject(explicit: explicit, repository: fromRepo(repo)), explicit, "explicit wins")
        XCTAssertEqual(reads, 0, "the repository is not read when an explicit identity is given")
        XCTAssertEqual(try GitIdentity.resolveForProject(explicit: nil, repository: fromRepo(repo)),
                       GitIdentity(name: "Repo User", email: "repo@example.com"), "repository used")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try GitIdentity.resolveForProject(explicit: GitIdentity(name: " A ", email: " a@b "), repository: .init()),
                       GitIdentity(name: "A", email: "a@b"), "trimmed")
        XCTAssertEqual(try GitIdentity.resolveForProject(explicit: nil, repository: .init(name: "\tR ", email: "r@x ")),
                       GitIdentity(name: "R", email: "r@x"), "repository values trimmed too")
    }

    /// Exact `CommandError.params` per case (arch. v0.11.20 §8.2): `missing`/`invalid` = `name` | `email` | `name,email`,
    /// found `name`/`email` = trimmed valid values; keys that don't apply are absent.
    func testIdentityRequiredParams() throws {
        let repo = GitIdentityFields(name: "Repo User", email: "repo@example.com")
        func params(_ e: GitIdentity?, _ r: GitIdentityFields = .init(), line: UInt = #line) -> [String: String]? {
            do { _ = try GitIdentity.resolveForProject(explicit: e, repository: r); XCTFail("resolved", line: line); return nil }
            catch let err as GitIdentityRequired {
                let ce = err.commandError
                XCTAssertEqual(ce.code, "identity_required", line: line)
                XCTAssertEqual(ce.code, CommandError.identityRequiredCode, line: line)
                XCTAssertEqual(ce.params, err.params, line: line)
                XCTAssertFalse(ce.params.values.contains(""), "no empty strings", line: line)
                return ce.params
            } catch { XCTFail("\(error)", line: line); return nil }
        }
        // Nothing anywhere.
        XCTAssertEqual(params(nil), ["missing": "name,email"])
        XCTAssertEqual(params(nil, .init(name: "  ", email: "")), ["missing": "name,email"], "present but blank = missing")
        // Half-set repository config.
        XCTAssertEqual(params(nil, .init(name: "Repo User")), ["missing": "email", "name": "Repo User"])
        XCTAssertEqual(params(nil, .init(email: " repo@example.com ")), ["missing": "name", "email": "repo@example.com"])
        // Explicit with an empty email → no fallback to the repository's email.
        XCTAssertEqual(params(GitIdentity(name: "Artem", email: ""), repo), ["missing": "email", "name": "Artem"])
        XCTAssertEqual(params(GitIdentity(name: " Artem ", email: "   "), repo), ["missing": "email", "name": "Artem"])
        XCTAssertEqual(params(GitIdentity(name: "", email: ""), repo), ["missing": "name,email"])
        // Line breaks / NUL.
        XCTAssertEqual(params(GitIdentity(name: "A\nB", email: "a@b")), ["invalid": "name", "email": "a@b"])
        XCTAssertEqual(params(GitIdentity(name: "A\nB", email: "")), ["invalid": "name", "missing": "email"])
        XCTAssertEqual(params(GitIdentity(name: "A", email: "a@b\0")), ["invalid": "email", "name": "A"])
        XCTAssertEqual(params(GitIdentity(name: "A\r", email: "a\nb")), ["invalid": "name,email"])
        XCTAssertEqual(params(nil, .init(name: "Repo\nUser")), ["invalid": "name", "missing": "email"], "from the repository too")

        // v0.11.21: whitespace-only after trimming (spaces, tabs) is `missing`, never `invalid`, explicit or from the repo;
        // each field lands in exactly one of missing / invalid / found, a rejected value is never returned.
        XCTAssertEqual(params(GitIdentity(name: "   ", email: "a@b")), ["missing": "name", "email": "a@b"])
        XCTAssertEqual(params(GitIdentity(name: "\t \t", email: " \t ")), ["missing": "name,email"])
        XCTAssertEqual(params(nil, .init(name: "   ", email: "repo@example.com")), ["missing": "name", "email": "repo@example.com"])
        XCTAssertEqual(params(nil, .init(name: " ", email: "\t")), ["missing": "name,email"])
        XCTAssertEqual(params(GitIdentity(name: "  ", email: "a\nb")), ["missing": "name", "invalid": "email"])
        XCTAssertEqual(params(GitIdentity(name: " \n ", email: "a@b")), ["invalid": "name", "email": "a@b"],
                       "a line break is not whitespace-only: invalid")
        // Order is always name before email, in both lists.
        XCTAssertEqual(params(GitIdentity(name: "\0", email: "\r"))?["invalid"], "name,email")
        XCTAssertEqual(params(GitIdentity(name: "", email: " "))?["missing"], "name,email")
        // Exactly one place per field, and rejected/blank values never come back.
        for (n, m) in [("", "a@b"), ("A\n", ""), (" ", "x\0"), ("A", "\t"), ("\r", "\n"), ("  ", "  ")] {
            let p = try XCTUnwrap(params(GitIdentity(name: n, email: m)))
            for f in ["name", "email"] {
                let places = [p["missing"]?.split(separator: ",").contains(Substring(f)) ?? false,
                              p["invalid"]?.split(separator: ",").contains(Substring(f)) ?? false,
                              p[f] != nil].filter { $0 }.count
                XCTAssertEqual(places, 1, "\(f) in \(p)")
            }
            XCTAssertFalse(p.values.contains { $0.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" } }, "\(p)")
        }

        // setProjectIdentity uses the same check.
        XCTAssertThrowsError(try GitIdentity(name: "Artem", email: "").validated()) {
            XCTAssertEqual(($0 as? GitIdentityRequired)?.params, ["missing": "email", "name": "Artem"])
        }
        // Structured value, not a single reason.
        XCTAssertThrowsError(try GitIdentity.resolveForProject(explicit: nil, repository: .init(name: "Repo User"))) {
            XCTAssertEqual($0 as? GitIdentityRequired,
                           GitIdentityRequired(missing: [.email], invalid: [], found: GitIdentityFields(name: "Repo User")))
        }
    }

    /// `CommandError` with these params survives the wire (protocol coder), including an empty `params`.
    func testIdentityRequiredCommandErrorRoundTrip() throws {
        let cases: [GitIdentityRequired] = [
            GitIdentityRequired(missing: [.name, .email]),
            GitIdentityRequired(missing: [.email], found: .init(name: "Артём Палкин")),
            GitIdentityRequired(invalid: [.name], found: .init(email: "a@b")),
            GitIdentityRequired(missing: [.email], invalid: [.name]),
        ]
        for c in cases {
            let e = c.commandError
            let data = try KabanCoding.makeEncoder().encode(e)
            let back = try KabanCoding.makeDecoder().decode(CommandError.self, from: data)
            XCTAssertEqual(back, e)
            XCTAssertEqual(back.params, c.params)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["params"] as? [String: String], c.params, "params on the wire as a flat string map")
        }
        // Sorted and stable: name before email regardless of insertion order.
        XCTAssertEqual(GitIdentityRequired(missing: [.email, .name]).params, ["missing": "name,email"])
        XCTAssertEqual(GitIdentityRequired(invalid: [.email, .name]).params, ["invalid": "name,email"])
    }

    /// Real git: the reader resolves like normal git in that repository (repo-local beats global), and with
    /// no config anywhere the resolver answers identity_required.
    func testIdentityFromRepositoryConfig() throws {
        let s = try Sandbox.make()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.git(["init", "-q", "-b", "main", "repo"])
        let repo = s.root.appendingPathComponent("repo").path
        let home = s.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The reader's environment is the user's normal one, isolated here from the box's real config.
        let isolated = ["PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        func required() -> [String: String]? {
            do { _ = try GitIdentity.resolveForProject(explicit: nil, repositoryPath: repo, environment: isolated); return nil }
            catch { return (error as? GitIdentityRequired)?.commandError.params }
        }

        // Nothing anywhere → identity_required, missing both.
        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: isolated), GitIdentityFields())
        XCTAssertEqual(required(), ["missing": "name,email"])
        // Explicit still works without any config.
        let explicit = GitIdentity(name: "Artem Palkin", email: "artem@example.com")
        XCTAssertEqual(try GitIdentity.resolveForProject(explicit: explicit, repositoryPath: repo, environment: isolated), explicit)

        // Name only (repo-local) → missing email, found name.
        try s.git(["-C", repo, "config", "user.name", "Repo Local"], env: isolated)
        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: isolated), GitIdentityFields(name: "Repo Local"))
        XCTAssertEqual(required(), ["missing": "email", "name": "Repo Local"])
        // Repo-local user.name + user.email are picked.
        try s.git(["-C", repo, "config", "user.email", "local@repo.invalid"], env: isolated)
        let local = GitIdentity(name: "Repo Local", email: "local@repo.invalid")
        XCTAssertEqual(try GitIdentity.resolveForProject(explicit: nil, repositoryPath: repo, environment: isolated), local)

        // Global config (normal resolution): used where the repo has nothing, repo-local wins where it has a value.
        try s.write("[user]\n\tname = Global User\n\temail = global@user.invalid\n", to: "home/.gitconfig")
        let normal = ["PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"]
        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: normal), GitIdentityFields(local), "repo-local beats global")
        try s.git(["-C", repo, "config", "--unset", "user.email"], env: normal)
        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: normal),
                       GitIdentityFields(name: "Repo Local", email: "global@user.invalid"), "per key, as git resolves")

        // v0.11.21: a git-config value of only spaces (quoted in the config file) is `missing`, on the first call without
        // identity; the valid email from the repo is returned as found.
        try s.git(["-C", repo, "config", "user.email", "local@repo.invalid"], env: isolated)
        try s.git(["-C", repo, "config", "user.name", "   "], env: isolated)
        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: isolated).name, "   ", "read as is")
        XCTAssertEqual(required(), ["missing": "name", "email": "local@repo.invalid"])
        try s.git(["-C", repo, "config", "user.name", "\t \t"], env: isolated)
        XCTAssertEqual(required(), ["missing": "name", "email": "local@repo.invalid"])
        try s.git(["-C", repo, "config", "user.name", "Repo Local"], env: isolated)

        // A multi-line value (escaped in config) is read as is and rejected as invalid — also on the first call.
        try s.git(["-C", repo, "config", "user.email", "a@b\nevil"], env: isolated)
        XCTAssertEqual(required(), ["invalid": "email", "name": "Repo Local"])
        try s.git(["-C", repo, "config", "user.email", "local@repo.invalid"], env: isolated)

        // An inherited GIT_DIR pointing elsewhere does not change which repository is read.
        try s.git(["init", "-q", "-b", "main", "other"])
        let other = s.root.appendingPathComponent("other").path
        try s.git(["-C", other, "config", "user.name", "Other"], env: isolated)
        try s.git(["-C", other, "config", "user.email", "other@x.invalid"], env: isolated)
        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: isolated.merging(["GIT_DIR": "\(other)/.git"]) { $1 }),
                       GitIdentityFields(local))

        XCTAssertEqual(GitIdentityFields.fromRepository(at: repo, environment: isolated, executable: "/nonexistent/git"), GitIdentityFields())
    }
}
