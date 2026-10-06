import Foundation
import KabanProtocol

/// Plans and checks task clones. Git runs only through `DaemonGit`, after the caller has committed the plan.
public enum TaskClone {
    public struct Plan: Equatable, Sendable {
        public var clonePath: String
        public var freshPath: String?
        public var branch: String
        public var derivedDataPath: String
        public var tempPath: String
        public var portStart: Int
        public var portEnd: Int
        public init(clonePath: String, freshPath: String?, branch: String, derivedDataPath: String, tempPath: String, portStart: Int, portEnd: Int) {
            self.clonePath = clonePath
            self.freshPath = freshPath
            self.branch = branch
            self.derivedDataPath = derivedDataPath
            self.tempPath = tempPath
            self.portStart = portStart
            self.portEnd = portEnd
        }
    }

    public enum Failure: Error, Equatable {
        case unsafeName
        case outsideWorkspace
        case foreignPath
        case originProtected
        case gitFailed
    }

    public static func plan(taskId: TaskID, title: String, projectId: ProjectID, stageId: StageID, fresh: Bool, workspaceRoot: String) throws -> Plan {
        let root = standardize(workspaceRoot)
        guard root.hasPrefix("/") else { throw Failure.outsideWorkspace }
        let project = try component(projectId.rawValue)
        let task = try component(taskId.rawValue)
        let clone = root + "/" + project + "/" + task
        let freshPath = fresh ? root + "/" + project + "/" + task + "--fresh-" + (try component(stageId.rawValue)) : nil
        let ports = portRange(taskId)
        return Plan(clonePath: clone, freshPath: freshPath, branch: branchName(taskId: taskId, title: title),
                    derivedDataPath: clone + "/DerivedData", tempPath: clone + "/.kaban-tmp", portStart: ports.0, portEnd: ports.1)
    }

    public static func branchName(taskId: TaskID, title: String) -> String {
        "kaban/\(piece(taskId.rawValue))-\(piece(title))"
    }

    /// Stable range of 100 ports in 20000...49999. The daemon records it; this function does not bind a socket.
    public static func portRange(_ taskId: TaskID) -> (Int, Int) {
        var hash: UInt32 = 2_166_136_261
        for byte in taskId.rawValue.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        let base = 20_000 + Int(hash % 300) * 100
        return (base, base + 99)
    }

    public static func authorizeDeletion(candidate: String, recorded: String, workspaceRoot: String, origin: String) throws {
        let root = standardize(workspaceRoot)
        let originPath = standardize(origin)
        let recordedPath = standardize(recorded)
        let candidatePath = standardize(candidate)
        guard candidatePath == recordedPath else { throw Failure.foreignPath }
        guard candidatePath != originPath, !isInside(originPath, candidatePath), !isInside(candidatePath, originPath) else { throw Failure.originProtected }
        guard !isInside(root, originPath), root != originPath else { throw Failure.originProtected }
        guard isInside(candidatePath, root) else { throw Failure.outsideWorkspace }
    }

    public static func materialize(_ plan: Plan, origin: String, workspaceRoot: String, identity: GitIdentity?, fresh: Bool) throws {
        let source = fresh ? plan.clonePath : origin
        let destination = fresh ? plan.freshPath! : plan.clonePath
        try authorizeDeletion(candidate: destination, recorded: destination, workspaceRoot: workspaceRoot, origin: origin)
        if FileManager.default.fileExists(atPath: destination) {
            try removeAuthorized(destination, recorded: destination, workspaceRoot: workspaceRoot, origin: origin)
        }
        try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try run(["clone", "--local", "--", source, destination], identity: identity)
        try run(["config", "core.hooksPath", "/dev/null"], in: destination, identity: identity)
        try run(["config", "core.fsmonitor", "false"], in: destination, identity: identity)
        try run(["remote", "set-url", "--push", "origin", "kaban-no-push"], in: destination, identity: identity)
        if !fresh {
            try run(["switch", "-c", plan.branch, "refs/heads/main"], in: destination, identity: identity)
            try FileManager.default.createDirectory(atPath: plan.derivedDataPath, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: plan.tempPath, withIntermediateDirectories: true)
        }
    }

    public static func removeAuthorized(_ candidate: String, recorded: String, workspaceRoot: String, origin: String) throws {
        try authorizeDeletion(candidate: candidate, recorded: recorded, workspaceRoot: workspaceRoot, origin: origin)
        guard FileManager.default.fileExists(atPath: candidate) else { return }
        try FileManager.default.removeItem(atPath: candidate)
    }

    public static func archiveTip(_ plan: Plan, taskId: TaskID, origin: String, identity: GitIdentity?) throws {
        let tip = try text(["rev-parse", "--verify", plan.branch], in: plan.clonePath, identity: identity)
        try run(["update-ref", "refs/kaban/archive/\(try component(taskId.rawValue))", tip], in: origin, identity: identity)
    }

    public static func head(_ repository: String, identity: GitIdentity?) throws -> String {
        try text(["rev-parse", "--verify", "HEAD"], in: repository, identity: identity)
    }

    public static func mainCommit(_ repository: String, identity: GitIdentity?) throws -> String {
        try text(["rev-parse", "--verify", "refs/heads/main"], in: repository, identity: identity)
    }

    public static func gitDirectory(_ repository: String, identity: GitIdentity?) throws -> String {
        try text(["rev-parse", "--absolute-git-dir"], in: repository, identity: identity)
    }

    public static func taskReady(_ plan: Plan, identity: GitIdentity?) -> Bool {
        guard (try? text(["rev-parse", "--verify", plan.branch], in: plan.clonePath, identity: identity)) != nil else { return false }
        guard (try? text(["config", "--get", "remote.origin.pushurl"], in: plan.clonePath, identity: identity)) == "kaban-no-push" else { return false }
        return FileManager.default.fileExists(atPath: plan.derivedDataPath) && FileManager.default.fileExists(atPath: plan.tempPath)
    }

    public static func freshReady(_ plan: Plan, identity: GitIdentity?) -> Bool {
        guard let fresh = plan.freshPath else { return true }
        guard (try? text(["rev-parse", "--verify", "HEAD"], in: fresh, identity: identity)) != nil else { return false }
        return (try? text(["config", "--get", "remote.origin.pushurl"], in: fresh, identity: identity)) == "kaban-no-push"
    }

    private static func component(_ value: String) throws -> String {
        let bad = value.isEmpty || value == "." || value == ".." || value.contains("/") || value.contains("\0") || value.contains("..")
        let scalars = value.unicodeScalars.contains { !CharacterSet.alphanumerics.contains($0) && $0 != "-" && $0 != "_" && $0 != "." }
        guard !bad && !scalars else { throw Failure.unsafeName }
        return value
    }

    private static func piece(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "task" : String(collapsed.prefix(32))
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Writes `refs/kaban/wip/<run>` inside this clone, then resets that clone to its current HEAD.
    /// Returns nil when the worktree is clean. Refuses a path that is not the recorded clone.
    public static func saveWipAndReset(clone: String, runId: RunID, recorded: String, workspaceRoot: String, origin: String, identity: GitIdentity?) throws -> String? {
        try authorizeDeletion(candidate: clone, recorded: recorded, workspaceRoot: workspaceRoot, origin: origin)
        guard FileManager.default.fileExists(atPath: clone) else { return nil }
        guard try worktreeDirty(clone, identity: identity) else { return nil }
        let ref = try wipRef(runId)
        let head = try text(["rev-parse", "HEAD"], in: clone, identity: identity)
        try run(["add", "-A"], in: clone, identity: identity)
        do {
            let tree = try text(["write-tree"], in: clone, identity: identity)
            let commit = try text(["commit-tree", tree, "-p", head, "-m", "kaban wip \(runId.rawValue)"], in: clone, identity: identity)
            try run(["update-ref", ref, commit], in: clone, identity: identity)
            try run(["reset", "--hard", head], in: clone, identity: identity)
            try run(["clean", "-fd"], in: clone, identity: identity)
            return ref
        } catch {
            _ = try? run(["reset", "--hard", head], in: clone, identity: identity)
            throw error
        }
    }

    public static func worktreeDirty(_ path: String, identity: GitIdentity?) throws -> Bool {
        try text(["status", "--porcelain"], in: path, identity: identity).isEmpty == false
    }

    public static let effectMarkerPrefix = "Kaban-Effect: "

    /// The commit that already carries `marker`, if this clone has it. A second caller must not create another.
    public static func findMarkedCommit(clone: String, marker: String, identity: GitIdentity?) throws -> String? {
        let raw = try text(["log", "-n", "40", "--format=%H%x1f%B%x1e"], in: clone, identity: identity)
        for record in raw.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            guard let split = record.firstIndex(of: "\u{1f}") else { continue }
            let sha = record[..<split]
            let body = record[record.index(after: split)...]
            if body.contains(marker) { return String(sha) }
        }
        return nil
    }

    /// Creates one commit for `marker` when the worktree is dirty. A replay that finds the marker returns that sha.
    /// Returns nil when there is nothing to commit. Uses `commit-tree`, so a hook planted in the clone does not run.
    public static func commitMarked(clone: String, message: String, marker: String, identity: GitIdentity?) throws -> String? {
        if let existing = try findMarkedCommit(clone: clone, marker: marker, identity: identity) { return existing }
        guard try worktreeDirty(clone, identity: identity) else { return nil }
        guard identity != nil else { throw Failure.gitFailed }
        try run(["add", "-A"], in: clone, identity: identity)
        let tree = try text(["write-tree"], in: clone, identity: identity)
        let head = try text(["rev-parse", "HEAD"], in: clone, identity: identity)
        let headTree = try text(["rev-parse", "HEAD^{tree}"], in: clone, identity: identity)
        guard tree != headTree else { return nil }
        let commit = try text(["commit-tree", tree, "-p", head, "-m", message + "\n\n" + marker], in: clone, identity: identity)
        try run(["update-ref", "HEAD", commit], in: clone, identity: identity)
        try run(["reset", "--hard", "HEAD"], in: clone, identity: identity)
        return commit
    }

    public static func diffstat(clone: String, from base: String, identity: GitIdentity?) throws -> String {
        guard !base.isEmpty else { return "" }
        return try text(["diff", "--stat", "\(base)..HEAD"], in: clone, identity: identity)
    }

    public static func commitSubjects(clone: String, from base: String, identity: GitIdentity?) throws -> String {
        guard !base.isEmpty else { return "" }
        return try text(["log", "--format=%H %s", "\(base)..HEAD"], in: clone, identity: identity)
    }

    public static func wipRef(_ runId: RunID) throws -> String {
        let raw = runId.rawValue
        let allowed = raw.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !raw.isEmpty, raw.count < 200, allowed else { throw Failure.unsafeName }
        return "refs/kaban/wip/\(raw)"
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path != root && path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func text(_ command: [String], in directory: String, identity: GitIdentity?) throws -> String {
        let data = try run(command, in: directory, identity: identity)
        var value = String(decoding: data, as: UTF8.self)
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    @discardableResult
    private static func run(_ command: [String], in directory: String? = nil, identity: GitIdentity?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DaemonGit.executable)
        process.arguments = try DaemonGit.arguments(command, in: directory, identity: identity)
        process.environment = DaemonGit.processEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count <= 1_048_576 else { throw Failure.gitFailed }
        return data
    }
}
