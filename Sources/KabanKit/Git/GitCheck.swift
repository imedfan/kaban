import Foundation
import KabanProtocol

/// Normalization and hard-boundary checks for one `/git/check` argv.
/// Configurable denies stay out of cursor-agent rules: those rules run before the shim,
/// so a later one-shot grant would never be asked.
public enum GitCheck {
    public static let deniedMessage = "команда запрещена политикой проекта, запрос отправлен человеку; продолжай без неё или дождись разрешения"

    /// Command names that may be placed in cursor-agent deny rules. Not a project or stage deny.
    public static let cursorHardDenyCommands = ["push", "remote", "config", "tag", "update-ref", "symbolic-ref", "filter-branch"]

    public static func cursorDenyRules(configurableDenies: [String] = []) -> [String] {
        _ = configurableDenies
        return cursorHardDenyCommands
    }

    /// Drops a leading `git` binary. A leading `-c` / `-C` / `--git-dir` / `--work-tree` / `--exec-path`
    /// becomes `config`, which the hard invariant already rejects.
    public static func normalize(argv: [String]) -> [String] {
        var args = argv
        if let first = args.first, first == "git" || first.hasSuffix("/git") {
            args.removeFirst()
        }
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "--" { break }
            if isDangerousGlobal(word) { return ["config"] }
            if skippableGlobals.contains(word) {
                index += 1
                continue
            }
            if word.hasPrefix("-") { break }
            break
        }
        return Array(args.dropFirst(index))
    }

    /// Hard invariant id for a normalized command, including `.kaban/` writes and call-time
    /// `notes` / `fetch` / `worktree` targets that name a protected base.
    public static func blocked(_ words: [String], baseBranch: String = "main") -> String? {
        let command = words.joined(separator: " ")
        if let id = GitPolicyResolver.hardInvariant(for: command) { return id }
        if writesKaban(words) { return HardInvariant.kabanDir }
        if let cmd = words.first, ["notes", "fetch", "worktree", "checkout", "switch", "rebase"].contains(cmd) {
            let targets = ["notes", "fetch", "worktree"].contains(cmd) ? Array(words.dropFirst()) : GitPolicyResolver.optionArgs(words)
            if targets.contains(where: { word in
                var target = word
                if cmd == "rebase", let equal = word.firstIndex(of: "="),
                   GitPolicyResolver.longOption(String(word[..<equal]), abbreviates: "--onto", minimum: "--on") {
                    target = String(word[word.index(after: equal)...])
                }
                return namesBase(target, branch: "main") || namesBase(target, branch: baseBranch)
            }) {
                return HardInvariant.foreignRefs
            }
        }
        return nil
    }

    public static func sameCommand(_ lhs: [String], _ rhs: [String]) -> Bool {
        normalize(argv: lhs) == normalize(argv: rhs)
    }

    private static let skippableGlobals: Set<String> = [
        "--no-pager", "--paginate", "--no-replace-objects", "--bare",
        "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs",
        "--no-optional-locks", "--no-lazy-fetch",
    ]

    private static func isDangerousGlobal(_ word: String) -> Bool {
        if word == "--git-dir" || word.hasPrefix("--git-dir=") { return true }
        if word == "--work-tree" || word.hasPrefix("--work-tree=") { return true }
        if word == "--exec-path" || word.hasPrefix("--exec-path=") { return true }
        if word == "--namespace" || word.hasPrefix("--namespace=") { return true }
        if word.hasPrefix("--") { return false }
        if word == "-c" || word.hasPrefix("-c") { return true }
        if word == "-C" || word.hasPrefix("-C") { return true }
        return false
    }

    private static func writesKaban(_ words: [String]) -> Bool {
        guard let cmd = words.first, !GitPolicyResolver.readCommands.contains(cmd) else { return false }
        return words.dropFirst().contains(where: pathHasKaban)
    }

    private static func pathHasKaban(_ word: String) -> Bool {
        if word == "--" || word.hasPrefix("-") { return false }
        return word.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".kaban" }
    }

    private static func namesBase(_ word: String, branch: String) -> Bool {
        var w = Substring(word)
        if let cut = w.firstIndex(where: { "~^@".contains($0) }) { w = w[..<cut] }
        return w == Substring(branch) || w.hasSuffix("/" + branch)
    }
}
