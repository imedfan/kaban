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

    public static func checkedOutBranch(_ repository: String, identity: GitIdentity?) throws -> String {
        try text(["rev-parse", "--abbrev-ref", "HEAD"], in: repository, identity: identity)
    }

    /// Worktree, index, and untracked paths. Rename records include both names.
    public static func dirtyPaths(_ repository: String, identity: GitIdentity?) throws -> [String] {
        let raw = try output(["status", "--porcelain", "--untracked-files=all", "-z"], in: repository, identity: identity, ok: [0], trim: false).text
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else { index += 1; continue }
            let status = record.prefix(2)
            paths.append(String(record.dropFirst(3)))
            if status.hasPrefix("R") || status.hasPrefix("C"), index + 1 < records.count {
                index += 1
                paths.append(records[index])
            }
            index += 1
        }
        return paths
    }

    public static func rebaseAncestor(base: String, tip: String, repository: String, identity: GitIdentity?) throws -> Bool {
        guard !base.isEmpty, !tip.isEmpty else { return false }
        return try output(["merge-base", "--is-ancestor", base, tip], in: repository, identity: identity, ok: [0, 1]).status == 0
    }

    public static func diffNames(from base: String, to tip: String, in repository: String, identity: GitIdentity?) throws -> [String] {
        guard !base.isEmpty, !tip.isEmpty else { return [] }
        return try text(["diff", "--name-only", base, tip], in: repository, identity: identity)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public struct MergeRebase: Equatable, Sendable {
        public var base: String
        public var tip: String
        public var conflicts: [String]
    }

    /// Rebases the task branch onto `origin`'s `main` inside a temporary clone under `workspaceRoot`.
    /// A conflict aborts that temporary clone. The user's checkout is not reset. A clean rebase
    /// `reset --hard`s only the task clone so the result check sees the rebased tree.
    public static func rebaseOntoMain(origin: String, clone: String, branch: String, workspaceRoot: String, taskId: TaskID, identity: GitIdentity?) throws -> MergeRebase {
        let task = try component(taskId.rawValue)
        let root = standardize(workspaceRoot)
        let directory = root + "/merge/" + task
        if FileManager.default.fileExists(atPath: directory) {
            try removeAuthorized(directory, recorded: directory, workspaceRoot: root, origin: origin)
        }
        try FileManager.default.createDirectory(atPath: (directory as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { try? removeAuthorized(directory, recorded: directory, workspaceRoot: root, origin: origin) }
        try run(["clone", "--local", "--", origin, directory], identity: identity)
        try run(["config", "core.hooksPath", "/dev/null"], in: directory, identity: identity)
        try run(["config", "core.fsmonitor", "false"], in: directory, identity: identity)
        try run(["fetch", clone, "\(branch):refs/heads/\(branch)"], in: directory, identity: identity)
        try run(["switch", branch], in: directory, identity: identity)
        let rebase = try output(["rebase", "refs/heads/main"], in: directory, identity: identity, ok: [0, 1])
        if rebase.status != 0 {
            let names = (try? output(["diff", "--name-only", "--diff-filter=U"], in: directory, identity: identity, ok: [0, 1]).text) ?? ""
            _ = try? run(["rebase", "--abort"], in: directory, identity: identity)
            let files = names.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            guard !files.isEmpty else { throw Failure.gitFailed }
            return MergeRebase(base: "", tip: "", conflicts: files)
        }
        let tip = try text(["rev-parse", "--verify", "HEAD"], in: directory, identity: identity)
        let base = try text(["rev-parse", "--verify", "refs/heads/main"], in: directory, identity: identity)
        try run(["fetch", directory, branch], in: clone, identity: identity)
        try run(["reset", "--hard", "FETCH_HEAD"], in: clone, identity: identity)
        return MergeRebase(base: base, tip: tip, conflicts: [])
    }

    /// Fast-forwards `refs/heads/main` to `tip`. A checkout of `main` uses `merge --ff-only`. Any other
    /// checkout updates the ref only, leaving the worktree and index alone. The caller must already
    /// have refused a dirty overlap and a moved base.
    public static func fastForwardMain(origin: String, clone: String, branch: String, tip: String, taskId: TaskID, identity: GitIdentity?) throws {
        let incoming = "refs/kaban/incoming/" + (try component(taskId.rawValue))
        try run(["fetch", clone, "\(branch):\(incoming)"], in: origin, identity: identity)
        let head = try checkedOutBranch(origin, identity: identity)
        if head == "main" {
            try run(["merge", "--ff-only", tip], in: origin, identity: identity)
        } else {
            try run(["update-ref", "refs/heads/main", tip], in: origin, identity: identity)
        }
        guard try mainCommit(origin, identity: identity) == tip else { throw Failure.gitFailed }
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

    /// Refs, tags and `config` of the main repository, excluding daemon archive refs.
    public struct ProtectionSnapshot: Codable, Hashable, Sendable {
        public var heads: [String: String]
        public var tags: [String: String]
        public var config: String
        public init(heads: [String: String], tags: [String: String], config: String) {
            self.heads = heads; self.tags = tags; self.config = config
        }
    }

    public struct BranchFile: Hashable, Sendable {
        public var file: ChangedFile
        public var isText: Bool
        public init(file: ChangedFile, isText: Bool) { self.file = file; self.isText = isText }
    }

    public static func captureProtection(_ origin: String, identity: GitIdentity?) throws -> ProtectionSnapshot {
        let gitDir = try text(["rev-parse", "--absolute-git-dir"], in: origin, identity: identity)
        let config = (try? String(contentsOfFile: gitDir + "/config", encoding: .utf8)) ?? ""
        return ProtectionSnapshot(heads: try refMap(origin, "refs/heads", identity), tags: try refMap(origin, "refs/tags", identity), config: config)
    }

    /// Restores `.cursor/mcp.json` to the `main` blob. The caller still excludes that path from the diff.
    public static func restoreBoardMCP(clone: String, origin: String, identity: GitIdentity?) throws {
        let destination = clone + "/.cursor/mcp.json"
        let shown = try output(["show", "refs/heads/main:.cursor/mcp.json"], in: origin, identity: identity, ok: [0, 128], trim: false)
        if shown.status == 0 {
            try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try shown.text.write(toFile: destination, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
    }

    public static func protectionDrift(_ origin: String, snapshot: ProtectionSnapshot, identity: GitIdentity?) throws -> IncidentKind? {
        let current = try captureProtection(origin, identity: identity)
        if current.heads != snapshot.heads { return .refsMoved }
        if current.tags != snapshot.tags { return .tagsChanged }
        if current.config != snapshot.config { return .configChanged }
        return nil
    }

    /// Puts the main repository's refs, tags and config back. Returns the names that were restored.
    public static func rollbackProtection(_ origin: String, snapshot: ProtectionSnapshot, identity: GitIdentity?) throws -> [String] {
        let current = try captureProtection(origin, identity: identity)
        var restored: [String] = []
        for (ref, sha) in snapshot.heads where current.heads[ref] != sha {
            try run(["update-ref", ref, sha], in: origin, identity: identity)
            restored.append(ref)
        }
        for ref in current.heads.keys where snapshot.heads[ref] == nil {
            try run(["update-ref", "-d", ref], in: origin, identity: identity)
            restored.append(ref)
        }
        for (ref, sha) in snapshot.tags where current.tags[ref] != sha {
            try run(["update-ref", ref, sha], in: origin, identity: identity)
            restored.append(ref)
        }
        for ref in current.tags.keys where snapshot.tags[ref] == nil {
            try run(["update-ref", "-d", ref], in: origin, identity: identity)
            restored.append(ref)
        }
        if current.config != snapshot.config {
            let gitDir = try text(["rev-parse", "--absolute-git-dir"], in: origin, identity: identity)
            try snapshot.config.write(toFile: gitDir + "/config", atomically: true, encoding: .utf8)
            restored.append("config")
        }
        return restored.sorted()
    }

    /// Committed `base...HEAD`, plus uncommitted and untracked files when `strict` is set.
    /// `.cursor/mcp.json` is omitted: the board server swapped it.
    public static func collectBranchFiles(clone: String, base: String, strict: Bool, identity: GitIdentity?) throws -> [BranchFile] {
        guard !base.isEmpty else { return [] }
        var byPath: [String: BranchFile] = [:]
        func take(_ file: BranchFile) {
            guard file.file.path != ".cursor/mcp.json" else { return }
            byPath[file.file.path] = file
        }
        for file in try diffFiles(clone: clone, spec: "\(base)...HEAD", worktree: false, identity: identity) { take(file) }
        if strict {
            for file in try diffFiles(clone: clone, spec: "HEAD", worktree: true, identity: identity) { take(file) }
            for file in try untrackedFiles(clone: clone, identity: identity) { take(file) }
        }
        return byPath.values.sorted { $0.file.path < $1.file.path }
    }

    /// Tracked, untracked, symlink, or directory replacement under `.kaban/`.
    public static func kabanChanged(clone: String, base: String, identity: GitIdentity?) throws -> Bool {
        if !base.isEmpty {
            let spec = "\(base)...HEAD"
            let committed = try output(["diff", "--name-only", spec, "--", ".kaban"], in: clone, identity: identity, ok: [0, 1, 128])
            let names: String
            if committed.status == 128 {
                // An orphan commit has no merge base, so the three-dot diff is undefined. Compare the trees;
                // a matching tree is foreign_base, not a .kaban edit.
                names = try output(["diff", "--name-only", base, "HEAD", "--", ".kaban"], in: clone, identity: identity, ok: [0, 1]).text
            } else {
                names = committed.text
            }
            if !names.isEmpty { return true }
        }
        let dirty = try text(["status", "--porcelain", "--untracked-files=all", "--", ".kaban"], in: clone, identity: identity)
        if !dirty.isEmpty { return true }
        let path = clone + "/.kaban"
        guard isSymlink(path) else { return false }
        let listed = try text(["ls-tree", base, "--", ".kaban"], in: clone, identity: identity)
        return !listed.contains("120000")
    }

    public static func foreignBase(clone: String, base: String, identity: GitIdentity?) throws -> Bool {
        guard !base.isEmpty else { return false }
        return try output(["merge-base", "--is-ancestor", base, "HEAD"], in: clone, identity: identity, ok: [0, 1]).status != 0
    }

    /// Drops task-branch commits that are not the recorded base, then removes untracked `.kaban` residue.
    public static func rollbackBranch(clone: String, base: String, identity: GitIdentity?) throws -> [String] {
        var restored: [String] = []
        let root = clone + "/.kaban"
        if isSymlink(root) {
            try FileManager.default.removeItem(atPath: root)
            restored.append(".kaban")
        }
        if !base.isEmpty {
            try run(["reset", "--hard", base], in: clone, identity: identity)
            restored.append(base)
        }
        let dirty = try text(["status", "--porcelain", "--untracked-files=all", "--", ".kaban"], in: clone, identity: identity)
        for line in dirty.split(separator: "\n") {
            let text = String(line)
            guard text.hasPrefix("?? ") else { continue }
            let relative = String(text.dropFirst(3))
            let full = clone + "/" + relative
            guard FileManager.default.fileExists(atPath: full) || isSymlink(full) else { continue }
            try FileManager.default.removeItem(atPath: full)
            restored.append(relative)
        }
        return restored
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

    private static func refMap(_ repository: String, _ prefix: String, _ identity: GitIdentity?) throws -> [String: String] {
        let raw = try text(["for-each-ref", "--format=%(refname)%00%(objectname)", prefix], in: repository, identity: identity)
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[0].hasPrefix("refs/kaban/") else { continue }
            out[parts[0]] = parts[1]
        }
        return out
    }

    private static func diffFiles(clone: String, spec: String, worktree: Bool, identity: GitIdentity?) throws -> [BranchFile] {
        let names = try output(["diff", "--name-status", "--find-renames", spec], in: clone, identity: identity, ok: [0, 1]).text
        let stats = try numstat(spec, in: clone, identity: identity)
        var out: [BranchFile] = []
        for line in names.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let status = parts.first, let path = parts.last else { continue }
            if status.hasPrefix("D") {
                out.append(BranchFile(file: ChangedFile(path: path, sizeBytes: 0, blob: "", deleted: true), isText: false))
                continue
            }
            let blob = try blobAndSize(clone: clone, path: path, worktree: worktree, identity: identity)
            out.append(BranchFile(file: ChangedFile(path: path, sizeBytes: blob.size, blob: blob.blob), isText: stats[path] ?? false))
        }
        return out
    }

    private static func untrackedFiles(clone: String, identity: GitIdentity?) throws -> [BranchFile] {
        let raw = try text(["ls-files", "--others", "--exclude-standard", "-z"], in: clone, identity: identity)
        var out: [BranchFile] = []
        for path in raw.split(separator: "\0") where !path.isEmpty {
            let relative = String(path)
            let blob = try blobAndSize(clone: clone, path: relative, worktree: true, identity: identity)
            let text = fileIsText(clone + "/" + relative)
            out.append(BranchFile(file: ChangedFile(path: relative, sizeBytes: blob.size, blob: blob.blob), isText: text))
        }
        return out
    }

    private static func numstat(_ spec: String, in clone: String, identity: GitIdentity?) throws -> [String: Bool] {
        let raw = try output(["diff", "--numstat", "--find-renames", spec], in: clone, identity: identity, ok: [0, 1]).text
        var out: [String: Bool] = [:]
        for line in raw.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let path = parts.last else { continue }
            out[path] = !(parts[0] == "-" && parts[1] == "-")
        }
        return out
    }

    private static func blobAndSize(clone: String, path: String, worktree: Bool, identity: GitIdentity?) throws -> (blob: String, size: Int64) {
        let blob: String
        if worktree {
            // Without -w the hash is not stored, so cat-file cannot size a new untracked blob.
            blob = try text(["hash-object", "-w", "--", path], in: clone, identity: identity)
        } else {
            blob = try text(["rev-parse", "--verify", "HEAD:\(path)"], in: clone, identity: identity)
        }
        let size = Int64(try text(["cat-file", "-s", blob], in: clone, identity: identity)) ?? 0
        return (blob, size)
    }

    private static func fileIsText(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return !data.contains(0)
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private struct GitOutput { var status: Int32; var text: String }
    private static func output(_ command: [String], in directory: String, identity: GitIdentity?, ok: Set<Int32>, trim: Bool = true) throws -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DaemonGit.executable)
        process.arguments = try DaemonGit.arguments(command, in: directory, identity: identity)
        process.environment = DaemonGit.processEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard ok.contains(process.terminationStatus), data.count <= 1_048_576 else { throw Failure.gitFailed }
        var value = String(decoding: data, as: UTF8.self)
        if trim, value.hasSuffix("\n") { value.removeLast() }
        return GitOutput(status: process.terminationStatus, text: value)
    }

    private static func text(_ command: [String], in directory: String, identity: GitIdentity?) throws -> String {
        try output(command, in: directory, identity: identity, ok: [0]).text
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
