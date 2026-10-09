import SwiftUI
import KabanProtocol
import KabanBoardCore

struct GitPermissionsView: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    let theme: KabanTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Разрешения git", systemImage: "key").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Не использовано · \(detail.task.unusedGitGrants)").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            if detail.gitDenials.isEmpty && detail.gitGrants.isEmpty {
                Text("Отказов и разовых разрешений пока нет.").font(.system(size: 12)).foregroundStyle(theme.secondary)
            }
            if let run = detail.runs.last {
                let count = detail.gitDenials.filter { $0.denial.runId == run.id }.count
                if count > 0 {
                    Text("Отказы за запуск #\(run.number) · \(count)/5. Пятый отказ останавливает запуск и ждёт решения человека.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(detail.gitDenials.sorted { $0.at > $1.at }, id: \.denial.denialId) { denial in
                GitDenialRow(store: store, detail: detail, denial: denial, theme: theme)
                Divider()
            }
            ForEach(detail.gitGrants.filter { grant in !detail.gitDenials.contains { $0.denial.denialId == grant.grant.denialId } }, id: \.grant.grantId) { grant in
                Text(grant.grant.argv.joined(separator: " ")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                GitGrantHistory(store: store, detail: detail, grant: grant, theme: theme)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.control, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct GitDenialRow: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    let denial: GitDenialSnapshot
    let theme: KabanTheme
    private var hard: Bool { denial.context?.restriction?.code == "git_hard_invariant" || GitPolicyPresentation.invariant(denial.denial.rule) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Отказ git", systemImage: hard ? "lock" : "nosign").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(denial.at, format: .dateTime.day().month().hour().minute().second()).font(.system(size: 10)).foregroundStyle(theme.faint)
            }
            Text(denial.denial.argv.joined(separator: " ")).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Аргументы команды") {
                ForEach(Array(denial.denial.argv.enumerated()), id: \.offset) { index, argument in
                    Text("[\(index)] \(argument)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.system(size: 10)).foregroundStyle(theme.secondary)
            Text("Правило · " + denial.denial.rule).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("Стадия · " + (denial.context?.stageId?.rawValue ?? "неизвестна") + " · " + runLabel)
                .font(.system(size: 11)).foregroundStyle(theme.secondary).textSelection(.enabled)
            if hard {
                Label(GitPolicyPresentation.invariant(denial.denial.rule)?.detail ?? "Жёсткое правило не настраивается.", systemImage: "lock.fill")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let failure = denial.context?.restriction {
                Text(failure.message).font(.system(size: 11)).foregroundStyle(theme.secondary)
            } else if denial.context == nil {
                Text("Служба не передала допустимость действий. Обновите детали или службу.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading, spacing: 6) { actions }
                }
            }
            GitCommandStatus(record: store.gitPermissions.receipt(in: .denial(denial.denial.denialId)), theme: theme)
            ForEach(detail.gitGrants.filter { $0.grant.denialId == denial.denial.denialId }, id: \.grant.grantId) { grant in
                GitGrantHistory(store: store, detail: detail, grant: grant, theme: theme)
            }
            ForEach(Array((denial.policyUpdates ?? []).enumerated()), id: \.offset) { _, update in
                VStack(alignment: .leading, spacing: 4) {
                    Label("Добавлено в политику · " + scopeLabel(update.scope), systemImage: "checkmark.shield")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                    Text("Версия .kaban/ · " + update.pipelineVersion).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(update.at, format: .dateTime.day().month().hour().minute().second()).font(.system(size: 10)).foregroundStyle(theme.secondary)
                    Text("Действует с новых запусков.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    DisclosureGroup("Принятая политика") { GitPolicyView(policy: update.policy, catalog: store.projection?.pipelines[detail.task.projectId]?.gitCommandCatalog ?? [], theme: theme) }
                        .font(.system(size: 11))
                }
            }
        }.accessibilityIdentifier("git-denial-" + denial.denial.denialId.rawValue)
    }
    @ViewBuilder private var actions: some View {
        Button("Разрешить один раз") { Task { await store.gitPermissions.allow(denial) } }
            .buttonStyle(KabanButtonStyle(compact: true)).disabled(!store.gitPermissions.canAllow(denial))
            .accessibilityIdentifier("git-allow-" + denial.denial.denialId.rawValue)
        Button("Добавить в политику…") { store.gitPermissions.openPreview(denial) }
            .buttonStyle(KabanButtonStyle(compact: true)).disabled(!store.gitPermissions.canPreview(denial))
            .accessibilityIdentifier("git-policy-" + denial.denial.denialId.rawValue)
    }
    private var runLabel: String {
        detail.runs.first { $0.id == denial.denial.runId }.map { "запуск #\($0.number) · \($0.id.rawValue)" } ?? "запуск · " + denial.denial.runId.rawValue
    }
}

struct GitGrantHistory: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    let grant: GitGrantSnapshot
    let theme: KabanTheme
    var body: some View {
        let presentation = GitGrantPresentation(grant, detail: detail)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(presentation.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(presentation.state == .inconsistent ? Color.orange : Color.green).frame(width: 5, height: 5)
                    Text(step.title).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let at = step.at { Text(at, format: .dateTime.day().month().hour().minute().second()).font(.system(size: 10)).foregroundStyle(theme.secondary) }
                    else { Text("Время неизвестно").font(.system(size: 10)).foregroundStyle(theme.secondary) }
                }
            }
            if let notice = presentation.notice { Text(notice).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true) }
            if grant.consumption == nil && grant.revocation == nil && grant.expiry == nil {
                Button("Отозвать разрешение") { Task { await store.gitPermissions.revoke(grant) } }
                    .buttonStyle(KabanButtonStyle(compact: true)).disabled(!store.gitPermissions.canRevoke(grant))
                    .accessibilityIdentifier("git-revoke-" + grant.grant.grantId.rawValue)
            }
            GitCommandStatus(record: store.gitPermissions.receipt(in: .grant(grant.grant.grantId)), theme: theme)
        }.padding(.leading, 12).id(grant.grant.grantId)
    }
}

struct GitCommandStatus: View {
    let record: ClientCommandJournal.Record?
    let theme: KabanTheme
    @ViewBuilder var body: some View {
        if let record {
            if record.isPending { Text("Ожидаем подтверждение службы…").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            else if case .rejected(let failure) = record.phase { Text(failure.message).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

private func scopeLabel(_ scope: PolicyScope) -> String {
    switch scope { case .project: "проект"; case .stage(let id): "стадия " + id.rawValue }
}
