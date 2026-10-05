import Foundation
import KabanProtocol
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Bounded, noninteractive local git operations. Never runs a shell or loads user hooks/filters.
public struct LocalGitRepository: Sendable {
    public let path: String
    public let repositoryID: String
    public init(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Self.error("invalid_path", "Укажите абсолютный путь к репозиторию.") }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue else {
            throw Self.error("project_missing", "Папка проекта не найдена.")
        }
        let root: String
        do { root = try Self.run(["rev-parse", "--show-toplevel"], at: canonical).text }
        catch { throw Self.error("not_git_repository", "Выберите рабочую папку Git-репозитория.") }
        let rootPath = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        do { _ = try Self.run(["rev-parse", "--verify", "refs/heads/main^{commit}"], at: rootPath) }
        catch { throw Self.error("base_branch_required", "Нужна локальная ветка main; другую базовую ветку демон не переключает.", ["baseBranch": "main"]) }
        self.path = rootPath
        let common = try Self.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: rootPath).text
        self.repositoryID = URL(fileURLWithPath: common).resolvingSymlinksInPath().standardizedFileURL.path
    }
    public func mainCommit() throws -> String { try git(["rev-parse", "--verify", "refs/heads/main^{commit}"]).text }
    public func branches() throws -> [String] { try git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]).text.split(separator: "\n").map(String.init).sorted() }
    public func pipeline() throws -> String? {
        let object = "refs/heads/main:.kaban/pipeline.yaml"
        let exists = try git(["cat-file", "-e", object], allowedFailure: true)
        guard exists.status == 0 else { return nil }
        let data = try git(["show", object], maxBytes: DaemonWire.maxPipelineBytes).data
        guard let yaml = String(data: data, encoding: .utf8) else { throw Self.error("pipeline_invalid", "pipeline.yaml должен быть UTF-8.") }
        return yaml
    }
    /// Compare the working .kaban tree with its committed main source without executing user
    /// conversion filters. Differences committed only on another branch are still unapplied in main.
    public func hasConfigurationEdits() throws -> Bool {
        let keys = try git(["config", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|smudge|process|required)$"], allowedFailure: true).text.split(separator: "\n").map(String.init)
        let configuration = keys.map { $0 + ($0.hasSuffix(".required") ? "=false" : "=") }
        let diff = try git(["diff", "--quiet", "--no-ext-diff", "--no-textconv", "refs/heads/main", "--", ".kaban"], allowedFailure: true, configuration: configuration)
        guard diff.status == 0 || diff.status == 1 else { throw Self.error("git_operation_failed", "Не удалось проверить правки .kaban/.") }
        if diff.status == 1 { return true }
        let staged = try git(["diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv", "refs/heads/main", "--", ".kaban"], allowedFailure: true, configuration: configuration)
        guard staged.status == 0 || staged.status == 1 else { throw Self.error("git_operation_failed", "Не удалось проверить staged правки .kaban/.") }
        if staged.status == 1 { return true }
        return try !git(["ls-files", "--others", "--exclude-standard", "-z", "--", ".kaban"]).data.isEmpty
    }
    public func gates() throws -> [String] {
        // Suggestions from committed build descriptors, never execute package scripts or inspect secrets.
        let files = Set(try git(["ls-tree", "--name-only", "refs/heads/main"]).text.split(separator: "\n").map(String.init))
        if files.contains("Package.swift") { return ["swift build", "swift test"] }
        if files.contains("pom.xml") { return [files.contains("mvnw") ? "./mvnw test" : "mvn test"] }
        if files.contains("build.gradle") || files.contains("build.gradle.kts") { return [files.contains("gradlew") ? "./gradlew test" : "gradle test"] }
        if files.contains("Cargo.toml") { return ["cargo build", "cargo test"] }
        if files.contains("go.mod") { return ["go build ./...", "go test ./..."] }
        if files.contains("package.json") { return ["npm test"] }
        return []
    }

    public struct TemplateCommit: Codable, Sendable {
        public let base: String
        public let commit: String
        public let blobs: [String: String]
    }
    /// Prepares objects only. The user's index, working files and refs are unchanged.
    public func prepareTemplate(identity: GitIdentity, commandId: CommandID) throws -> TemplateCommit {
        guard try git(["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true).text == "refs/heads/main" else {
            throw Self.error("template_checkout_required", "Для создания шаблона откройте main или добавьте проект без шаблона.", ["baseBranch": "main"])
        }
        guard (try? FileManager.default.attributesOfItem(atPath: path + "/.kaban")) == nil, try git(["ls-files", "--", ".kaban"]).data.isEmpty else {
            throw Self.error("template_conflict", "Существующие правки .kaban/ нельзя перезаписать; сохраните их или добавьте проект без шаблона.")
        }
        let base = try mainCommit()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let index = scratch.appendingPathComponent("index").path
        _ = try git(["read-tree", base], index: index)
        var blobs: [String: String] = [:]
        for name in PipelineTemplate.files.keys.sorted() {
            let blob = try git(["hash-object", "-w", "--no-filters", "--stdin"], input: Data(PipelineTemplate.files[name]!.utf8)).text
            blobs[name] = blob
            _ = try git(["update-index", "--add", "--cacheinfo", "100644", blob, name], index: index)
        }
        let tree = try git(["write-tree"], index: index).text
        let commit = try git(["commit-tree", tree, "-p", base], identity: identity,
                             input: Data("Add Kaban template\n\nKaban-Command: \(commandId.uuidString.lowercased())\n".utf8)).text
        return TemplateCommit(base: base, commit: commit, blobs: blobs)
    }
    /// Reconciles facts after a lost response/crash. CAS never overwrites a concurrent main update.
    /// Existing working files are never overwritten, including edits made during recovery.
    public func finishTemplate(_ plan: TemplateCommit) throws {
        let current = try mainCommit()
        if current == plan.base {
            guard try git(["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true).text == "refs/heads/main",
                  (try? FileManager.default.attributesOfItem(atPath: path + "/.kaban")) == nil else {
                throw Self.error("template_conflict", "Checkout изменился до создания шаблона.")
            }
            _ = try git(["update-ref", "-m", "Kaban template", "refs/heads/main", plan.commit, plan.base])
        } else if current != plan.commit {
            guard try git(["merge-base", "--is-ancestor", plan.commit, current], allowedFailure: true).status == 0 else {
                throw Self.error("git_race", "main изменился; повторите добавление новой командой.")
            }
            // Our commit is already in history; do not reset a newer user commit/index/worktree.
            return
        }
        guard try git(["symbolic-ref", "--quiet", "HEAD"], allowedFailure: true).text == "refs/heads/main" else { return }
        for name in plan.blobs.keys.sorted() {
            let data = try git(["cat-file", "blob", plan.blobs[name]!]).data
            try installTemplateFile(name, data: data)
        }
        // Only missing index entries from the committed template are added. Preserve a user's
        // concurrently edited/staged .kaban file as well as every unrelated staged entry.
        let indexed = try git(["ls-files", "-z", "--", ".kaban"]).data
        let names = Set(String(decoding: indexed, as: UTF8.self).split(separator: "\0").map(String.init))
        let records = plan.blobs.keys.sorted().filter { !names.contains($0) }.map { "100644 \(plan.blobs[$0]!)\t\($0)\n" }.joined()
        if !records.isEmpty { _ = try git(["update-index", "--index-info"], input: Data(records.utf8)) }
    }
    /// Anchor every lookup to directory descriptors. O_NOFOLLOW and an exclusive link prevent
    /// a concurrent symlink replacement from redirecting a template write outside the repository.
    private func installTemplateFile(_ name: String, data: Data) throws {
        let components = name.split(separator: "/").map(String.init)
        guard components.first == ".kaban", components.count >= 2, !components.contains("..") else {
            throw Self.error("template_conflict", "Некорректный путь шаблона.")
        }
        var directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.error("project_missing", "Папка проекта недоступна.") }
        defer { close(directory) }
        for component in components.dropLast() {
            if mkdirat(directory, component, 0o755) != 0 && errno != EEXIST {
                throw Self.error("template_conflict", "Не удалось создать папку шаблона.")
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.error("template_conflict", ".kaban/ содержит ссылку или конфликтующий файл.") }
            close(directory); directory = next
        }
        let temporary = ".kaban-write-" + UUID().uuidString.lowercased()
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw Self.error("template_conflict", "Не удалось записать шаблон.") }
        defer { close(file); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.error("template_conflict", "Не удалось записать шаблон.") }
                offset += count
            }
        }
        if linkat(directory, temporary, directory, components.last!, 0) != 0 && errno != EEXIST {
            throw Self.error("template_conflict", "Не удалось установить файл шаблона.")
        }
    }
    struct Output { let data: Data; let status: Int32; var text: String {
        var value = String(decoding: data, as: UTF8.self)
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    } }
    func git(_ args: [String], identity: GitIdentity? = nil, index: String? = nil, input: Data = Data(), allowedFailure: Bool = false, maxBytes: Int = 4_194_304, configuration: [String] = []) throws -> Output {
        try Self.run(args, at: path, identity: identity, index: index, input: input, allowedFailure: allowedFailure, maxBytes: maxBytes, configuration: configuration)
    }
    private static func run(_ args: [String], at path: String, identity: GitIdentity? = nil, index: String? = nil,
                            input: Data = Data(), allowedFailure: Bool = false, maxBytes: Int = 4_194_304, configuration: [String] = []) throws -> Output {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputURL = scratch.appendingPathComponent("in"), outputURL = scratch.appendingPathComponent("out")
        try input.write(to: inputURL); try Data().write(to: outputURL)
        let stdin = try FileHandle(forReadingFrom: inputURL), stdout = try FileHandle(forWritingTo: outputURL)
        defer { try? stdin.close(); try? stdout.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DaemonGit.executable)
        process.arguments = configuration.flatMap { ["-c", $0] } + (try DaemonGit.arguments(args, in: path, identity: identity))
        var environment = DaemonGit.processEnvironment
        // Only an internally allocated scratch index; never a caller-supplied environment override.
        if let index { environment["GIT_INDEX_FILE"] = index }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_REPLACE_OBJECTS"] = "1" // Blob/commit IDs must remain immutable source identities.
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning {
            let bytes = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if Date() > deadline || bytes > maxBytes {
                kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                throw error("git_operation_limit", "Git превысил лимит времени или размера ответа.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: outputURL)
        guard data.count <= maxBytes else { throw error("git_operation_limit", "Ответ Git превышает лимит.") }
        guard allowedFailure || process.terminationStatus == 0 else { throw error("git_operation_failed", "Не удалось выполнить локальную Git-операцию.") }
        return Output(data: data, status: process.terminationStatus)
    }
    static func error(_ code: String, _ message: String, _ params: [String: String] = [:]) -> CommandError { .init(code: code, message: message, params: params) }
}
