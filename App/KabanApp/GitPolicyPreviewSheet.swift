import SwiftUI
import KabanProtocol
import KabanBoardCore

struct GitPolicyPreviewSheet: View {
    @Bindable var board: BoardStore
    @Bindable var preview: GitPolicyPreviewStore
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Добавить правило в политику", systemImage: "shield").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Закрыть") { board.gitPermissions.preview = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(KabanButtonStyle(compact: true))
            }.padding(20)
            if let version = preview.acceptedVersion {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Правило сохранено и закоммичено", systemImage: "checkmark.shield").font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                    Text("Версия .kaban/ · " + version).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.bottom, 12)
            } else if preview.editor.isApplied {
                Text("Команда подтверждена. Проверяем committed версию и точный исходный текст…")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(preview.denial.context?.policyRule ?? "Правило неизвестно")
                        .font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(board.projection?.projects[preview.editor.projectID]?.name ?? preview.editor.projectID.rawValue)
                        .font(.system(size: 12)).foregroundStyle(theme.secondary)
                    Picker("Область", selection: Binding(get: { preview.scope == .project ? "project" : "stage" }, set: { value in
                        guard let stage = preview.denial.context?.stageId else { return }
                        Task { await preview.choose(value == "project" ? .project : .stage(stage)) }
                    })) {
                        Text("Весь проект").tag("project")
                        Text("Стадия " + (preview.denial.context?.stageId?.rawValue ?? "неизвестна")).tag("stage")
                    }.pickerStyle(.segmented).disabled(preview.editor.loading || preview.editor.isPending || preview.editor.isApplied)
                        .accessibilityIdentifier("git-policy-scope")
                    Text("Сохранение коммитит .kaban/ с автором проекта. Новая политика действует с будущих запусков; текущий запуск сохраняет свою версию.")
                        .font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    if preview.editor.loading { ProgressView("Читаем pipeline…") }
                    if let error = preview.error ?? preview.editor.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    validation
                    if let policy = preview.policy {
                        GitPolicyView(policy: policy, catalog: preview.editor.lastResolved?.gitCommandCatalog ?? [], theme: theme,
                                      title: preview.scope == .project ? "Политика проекта после изменения" : "Политика стадии после изменения")
                        if !preview.ruleAllowed {
                            Text("Правило остаётся запрещённым. Запрет выше по политике или read-only доступ нельзя снять этим разрешением.")
                                .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !preview.editor.loading {
                        Text("Служба ещё не передала итоговую политику. Сохранение недоступно.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                    }
                    DisclosureGroup("Точный YAML, который будет сохранён") {
                        Text(preview.editor.content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.control, in: RoundedRectangle(cornerRadius: 7))
                    }.font(.system(size: 12))
                    GitCommandStatus(record: preview.editor.receipt, theme: theme)
                }.padding(20)
            }
            Divider()
            HStack {
                Button("Проверить снова") { Task { await preview.editor.readSource(); await preview.editor.validate() } }
                    .buttonStyle(KabanButtonStyle()).disabled(preview.editor.isPending)
                Spacer()
                Button("Сохранить и закоммитить") { Task { await preview.save() } }
                    .buttonStyle(KabanButtonStyle(primary: true)).disabled(!preview.canSave).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("git-policy-save")
            }.padding(16)
        }.frame(width: 650, height: 610).background(theme.window)
            .task { await preview.load() }
            .task(id: board.canSend && preview.editor.isApplied) {
                if preview.editor.isApplied { await preview.editor.confirmApplied() }
            }
    }
    @ViewBuilder private var validation: some View {
        switch preview.editor.validation {
        case .idle: Text("Черновик ещё не проверен.").font(.system(size: 12)).foregroundStyle(theme.secondary)
        case .checking: ProgressView("Проверяем правило…")
        case .unavailable(let message): Text(message).font(.system(size: 12)).foregroundStyle(.orange)
        case .checked(let result):
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                Text(issue.message).font(.system(size: 12)).foregroundStyle(issue.severity == .error ? Color.red : Color.orange).textSelection(.enabled)
            }
        }
    }
}
