import Foundation
import KabanProtocol

/// The single place for the daemon's OWN git calls inside a task clone (merge, safety commit, checkout, resync, status …),
/// arch. v0.11.19 §8.2. The clone is agent-writable, so nothing it contains may run outside the sandbox or wait for input:
/// - argv: `-c core.hooksPath=/dev/null -c core.fsmonitor=false` before the subcommand (no planted hook, no fsmonitor
///   command from the clone's config); the caller's own global options before the subcommand are rejected;
/// - environment: built from scratch by a whitelist — every inherited `GIT_*` is dropped, the daemon sets exactly
///   `GIT_EDITOR=true`, `GIT_SEQUENCE_EDITOR=true`, `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_GLOBAL=/dev/null`,
///   `GIT_CONFIG_NOSYSTEM=1` (no user `credential.helper`, `includeIf`, aliases, pager), and of the rest only `PATH`,
///   `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `LANG`/`LC_*` survive (`HOME` is not for config — git reads no global config
///   here — but for `~` in paths and for child tools);
/// - author: the project's `GitIdentity` (protocol type, stored in project settings, resolved once at `addProject` by
///   `GitIdentity.resolveForProject`), passed explicitly as `-c user.name=… -c user.email=…` and validated on every call;
/// - `merge` always carries `--no-edit`; `merge --edit`/`-e` is rejected.
/// Command-line `-c` wins over the clone's config. Agent git calls go through `/git/check` and the policy instead.
public enum DaemonGit {
    public static let executable = "/usr/bin/git"

    /// `key=value` pairs passed as `-c key=value`, in this order.
    public static let hardeningConfig: [String] = ["core.hooksPath=/dev/null", "core.fsmonitor=false"]

    /// `["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]`.
    public static var hardeningArguments: [String] { hardeningConfig.flatMap { ["-c", $0] } }

    /// The only `GIT_*` variables a daemon git call sees (§8.2): no editor, no sequence editor, no terminal prompt,
    /// no global or system config.
    public static let environment: [String: String] = [
        "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true", "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    ]

    /// Non-`GIT_*` variables taken from the base environment; everything else is dropped (`SSH_ASKPASS`, `EDITOR`,
    /// `VISUAL`, `XDG_CONFIG_HOME`, `DYLD_*`, …). `HOME` is kept for `~` in paths and child tools, not for git config
    /// (with `GIT_CONFIG_GLOBAL=/dev/null` git does not read `~/.gitconfig`), arch. v0.11.19 §8.2.
    public static let inheritedWhitelist: Set<String> = ["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG"]
    /// Plus every locale variable (`LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`, …), arch. v0.11.17 «`LANG`/`LC_*`».
    public static let inheritedPrefixes: [String] = ["LC_"]

    public static func isInherited(_ key: String) -> Bool {
        !key.hasPrefix("GIT_") && (inheritedWhitelist.contains(key) || inheritedPrefixes.contains { key.hasPrefix($0) })
    }

    /// The environment for a daemon git call, built from scratch: the whitelisted entries of `base` (e.g. the daemon's
    /// process environment) plus `environment`. No inherited `GIT_*` survives (`GIT_DIR`, `GIT_WORK_TREE`,
    /// `GIT_INDEX_FILE`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`/`KEY_*`/`VALUE_*`, `GIT_EXEC_PATH`,
    /// `GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, `GIT_ASKPASS`, …), and the daemon's own values always win.
    public static func environment(merging base: [String: String]) -> [String: String] {
        var env = base.filter { key, _ in isInherited(key) }
        for (k, v) in environment { env[k] = v }
        return env
    }

    /// `environment(merging:)` over the current process environment.
    public static var processEnvironment: [String: String] { environment(merging: ProcessInfo.processInfo.environment) }

    public enum BuildError: Error, Equatable, Sendable {
        /// The caller's own global options before the subcommand are rejected (§8.2): `-c`, `-C`, `--git-dir`,
        /// `--work-tree`, `--exec-path` (also in `--opt=value` form) and any other option there (`--config-env`, …).
        case globalOptionNotAllowed(String)
        /// `merge --edit`/`-e` would contradict the mandatory `--no-edit`.
        case editNotAllowed(String)
        /// A subcommand that writes commits needs the explicit author (§8.2): with global and system config off, git would
        /// otherwise fail late or fall back to `user@host`. Defensive: a registered project always has an identity.
        case identityRequired(String)
        /// The passed identity has an empty name/email or a line break/NUL (it would corrupt the `-c` value).
        case invalidIdentity(GitIdentityRequired)
        case emptyCommand
    }

    /// Subcommands that create commits and therefore require `identity`.
    public static let commitWritingCommands: Set<String> = ["commit", "merge", "rebase", "cherry-pick", "revert", "am", "stash"]

    /// argv (without the executable): `git [-C directory] -c <hardening>… [-c user.name=… -c user.email=…] <subcommand> <args…>`;
    /// for `merge`, `--no-edit` is inserted right after the subcommand if the caller did not pass it.
    /// - Parameters:
    ///   - command: subcommand and its arguments, e.g. `["merge", "--no-ff", "kaban/t-1"]`. Options after the subcommand
    ///     belong to it (`switch -c x`, `commit -C HEAD`, `rev-parse --git-dir` are fine).
    ///   - directory: the clone; emitted as the builder's own `-C <directory>`.
    ///   - identity: the author/committer; required for `commitWritingCommands`, optional (and still passed) otherwise.
    public static func arguments(_ command: [String], in directory: String? = nil, identity: GitIdentity? = nil) throws -> [String] {
        guard let sub = command.first, !sub.isEmpty else { throw BuildError.emptyCommand }
        if sub.hasPrefix("-") { throw BuildError.globalOptionNotAllowed(sub) }
        if identity == nil && commitWritingCommands.contains(sub) { throw BuildError.identityRequired(sub) }
        let author: GitIdentity?
        do { author = try identity?.validated() } catch let e as GitIdentityRequired { throw BuildError.invalidIdentity(e) }
        var command = command
        if sub == "merge" {
            if let edit = command.dropFirst().prefix(while: { $0 != "--" }).first(where: { $0 == "--edit" || $0 == "-e" }) {
                throw BuildError.editNotAllowed(edit)
            }
            if !command.contains("--no-edit") { command.insert("--no-edit", at: 1) }
        }
        return (directory.map { ["-C", $0] } ?? []) + hardeningArguments + (author?.configArguments ?? []) + command
    }

    /// `merge` through the builder: `git [-C directory] -c … merge --no-edit <args…>`.
    public static func merge(_ args: [String], in directory: String? = nil, identity: GitIdentity?) throws -> [String] {
        try arguments(["merge"] + args, in: directory, identity: identity)
    }

    /// Full argv including the executable, for `posix_spawn`/`Process`.
    public static func argv(_ command: [String], in directory: String? = nil, identity: GitIdentity? = nil) throws -> [String] {
        [executable] + (try arguments(command, in: directory, identity: identity))
    }
}
