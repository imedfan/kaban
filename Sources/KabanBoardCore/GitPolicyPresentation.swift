import KabanProtocol

public enum GitPolicyPresentation {
    public struct Group: Equatable {
        public let source: GitRuleSource?
        public var rules: [String]
    }
    public static func groups(_ rules: [GitRule]) -> [Group] {
        var groups: [Group] = []
        for rule in rules {
            if let index = groups.firstIndex(where: { $0.source == rule.source }) { groups[index].rules.append(rule.rule) }
            else { groups.append(.init(source: rule.source, rules: [rule.rule])) }
        }
        return groups
    }
    public static func label(source: GitRuleSource?, denied: Bool, readOnly: Bool) -> String? {
        switch source {
        case .preset, .project: "унаследовано"
        case .stage: denied ? (readOnly ? "сужено до чтения" : "сужено") : "переопределено"
        case nil: nil
        }
    }
    public static func outsidePreset(catalog: [String], policy: EffectiveGitPolicy) -> [String] {
        let listed = Set((policy.allowed + policy.denied).map(\.rule))
        return catalog.filter { !listed.contains($0) }
    }
    public static func invariant(_ id: String) -> (title: String, detail: String)? {
        switch id {
        case "push": ("Без push", "Агент не пушит.")
        case "remote": ("Remotes не меняются", "Агент не меняет remotes.")
        case "config": ("Git config и hooks не меняются", "Агент не меняет git config и не пишет в .git/config, .git/hooks/, .git/info/ клона. Это запрещает песочница. Демон вызывает git с отключёнными hooks и fsmonitor.")
        case "tag": ("Теги не трогаются", "Агент не создаёт и не двигает теги.")
        case "force": ("Без принудительных флагов", "Запрещены --force* на любой команде, в том числе rebase --force-rebase, и принудительный -f у checkout, switch, add, rm, mv, clean, worktree, submodule, включая связки вроде -fd. grep -f, blame -f, ls-files -f разрешены. clean разрешён только с -n или --dry-run, включая clean -i и clean без -f: удаление неотслеживаемых файлов не отменить.")
        case "foreign_refs": ("main и чужие ветки не двигаются", "Агент не двигает main и чужие ветки, включая checkout/switch/rebase на main в любой записи, origin/main, refs/heads/main, main~n; удаление веток, branch -f/-m/-M/-C, checkout -B, switch -C, update-ref, symbolic-ref, filter-branch, reflog expire. Обычное создание ветки -b/-c сюда не входит. Цель записи notes, fetch и worktree проверяет /git/check.")
        case "kaban_dir": (".kaban/ только для демона", "Агент не пишет в .kaban/. Это блокируют /git/check и песочница.")
        default: nil
        }
    }
}
