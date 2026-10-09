import SwiftUI
import KabanProtocol
import KabanBoardCore

struct ProjectMetadataView: View {
    @Bindable var settings: ProjectSettingsStore
    @Bindable var board: BoardStore
    let theme: KabanTheme
    @FocusState private var identityFocus: IdentityField?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Проект · на этом Маке").font(.system(size: 13, weight: .semibold))
            Text("Локальная база службы Kaban. Сохраняется сразу, без commit .kaban/.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            if let project = settings.project {
                row("Основная ветка", project.baseBranch)
                row("Вес проекта", String(project.weight))
                row("Процессов одновременно", project.maxRuns.map(String.init) ?? "Без личного лимита")
                row("Автор коммитов", project.identity.map { "\($0.name) <\($0.email)>" } ?? "—")
                HStack {
                    Button("Изменить автора…") { settings.begin(.identity) }.buttonStyle(KabanButtonStyle(compact: true))
                        .disabled(settings.isPending || !board.can(.setProjectIdentity))
                    Button("Вес и личный максимум…") { settings.begin(.resources) }.buttonStyle(KabanButtonStyle(compact: true))
                        .disabled(settings.isPending || !board.can(.setProjectWeight))
                    Button("Маскот…") { board.mascotProjectID = settings.projectID }.buttonStyle(KabanButtonStyle(compact: true))
                        .disabled(settings.isPending || !board.can(.setMascot))
                }
                if let section = settings.section {
                    Divider()
                    if section == .identity {
                        identityField("Имя", .name, settings.identity.name)
                        identityField("Почта", .email, settings.identity.email)
                        Text("С новых коммитов. Уже сделанные коммиты не переписываются.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    } else {
                        input("Вес", value: Binding(get: { settings.weight }, set: { settings.editWeight($0) }), identifier: "project-weight")
                        input("Личный максимум", value: Binding(get: { settings.maxRuns }, set: { settings.editMaxRuns($0) }), identifier: "project-max-runs")
                        Text("Вес и максимум должны быть положительными целыми числами. Пустой максимум снимает личный лимит. Текущие запуски продолжаются.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                    }
                    if let error = settings.error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Button("Отмена") { settings.cancel() }.buttonStyle(KabanButtonStyle()).disabled(settings.isPending).keyboardShortcut(.escape, modifiers: [])
                        Spacer()
                        if settings.isPending { Text("Ожидаем подтверждение службы").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                        Button("Сохранить") { Task { await settings.submit() } }.buttonStyle(KabanButtonStyle(primary: true))
                            .disabled(!settings.canSubmit).keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 0.5))
            .onChange(of: settings.record?.phase) { _, _ in settings.observeOutcome(); identityFocus = settings.identity.focus }
            .onChange(of: settings.section) { _, section in if section == .identity { identityFocus = .name } }
    }
    private func identityField(_ title: String, _ field: IdentityField, _ draft: IdentityFieldDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).frame(width: 140, alignment: .leading)
                TextField(title, text: Binding(get: { field == .name ? settings.identity.name.value : settings.identity.email.value },
                    set: { settings.editIdentity(field, value: $0) })).textFieldStyle(.roundedBorder).focused($identityFocus, equals: field)
                    .disabled(settings.isPending).accessibilityIdentifier("project-identity-" + field.rawValue)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(draft.highlighted ? .orange : .clear, lineWidth: 1))
            }
            if let caption = draft.caption { Text(caption).foregroundStyle(.orange).padding(.leading, 148) }
        }.font(.system(size: 12))
    }
    private func input(_ title: String, value: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(title).frame(width: 140, alignment: .leading)
            TextField(title, text: value).textFieldStyle(.roundedBorder).disabled(settings.isPending).accessibilityIdentifier(identifier)
        }.font(.system(size: 12))
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.system(size: 12)).foregroundStyle(theme.secondary).frame(width: 180, alignment: .leading)
            Text(value).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
