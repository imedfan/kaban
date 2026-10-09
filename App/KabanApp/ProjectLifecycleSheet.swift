import SwiftUI
import Observation
import KabanProtocol
import KabanBoardCore

/// These bookmarks grant the App access, never prove the helper's permissions.
@MainActor @Observable final class ProjectFolderAccess {
    private let storage: any KeyValueStoring
    private let key: String
    private var bookmarks: [String: Data] = [:]
    private var active: [String: URL] = [:]
    var error: String?
    init(storage: any KeyValueStoring, key: String) {
        self.storage = storage; self.key = key
        do {
            bookmarks = try storage.data(forKey: key).map { try JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
            for (path, data) in bookmarks {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale { error = "Разрешение папки устарело. Выберите папку снова." }
                else if url.startAccessingSecurityScopedResource() { active[path] = url }
                else { error = "Не удалось восстановить разрешение папки. Выберите её снова." }
            }
        } catch { self.error = "Не удалось восстановить доступ к папке. Выберите её снова. " + error.localizedDescription }
    }
    isolated deinit { for url in active.values { url.stopAccessingSecurityScopedResource() } }
    func remember(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        var retained = false
        defer { if started && !retained { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmarks[url.path] = data
            storage.set(try JSONEncoder().encode(bookmarks), forKey: key)
            if started {
                active[url.path]?.stopAccessingSecurityScopedResource()
                active[url.path] = url; retained = true
            }
            error = nil
        } catch { self.error = "Не удалось сохранить разрешение папки. Выберите её снова после перезапуска. " + error.localizedDescription }
    }
}

enum ProjectSheetRoute: Identifiable {
    case add, relink(ProjectID), remove(ProjectID)
    var operation: ProjectOperation {
        switch self { case .add: .add; case .relink(let id): .relink(id); case .remove(let id): .remove(id) }
    }
    var id: String {
        switch self { case .add: "add-project"; case .relink(let id): "relink-" + id.rawValue; case .remove(let id): "remove-" + id.rawValue }
    }
}

struct ProjectLifecycleSheet: View {
    @Bindable var store: BoardStore
    let route: ProjectSheetRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var identityFocus: IdentityField?
    private var model: ProjectLifecycleStore { store.projects }
    private var theme: KabanTheme { .init(dark: scheme == .dark) }
    private var removing: Bool { if case .remove = route { true } else { false } }
    private var title: String {
        switch route { case .add: "Добавить проект"; case .relink: "Переподключить проект"; case .remove: "Удалить проект из Kaban?" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: removing ? "folder.badge.minus" : "folder")
                    .font(.system(size: 17)).frame(width: 36, height: 36).foregroundStyle(theme.accent)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(removing ? "Репозиторий на диске останется на месте" : "Папка git-репозитория на этом Маке")
                        .font(.system(size: 12)).foregroundStyle(theme.secondary)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть")
            }.padding(24)
            Divider().overlay(theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.formError { refusal(error) }
                    if model.phase == .applied { result }
                    else if removing { removalExplanation }
                    else { folderForm }
                    if let text = pendingText { note(text + " Можно закрыть лист — отправка сохранена.") }
                    if !store.canSend { note(store.connectionLabel ?? "Дождитесь подключения к службе Kaban.") }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: formHeight)
            Divider().overlay(theme.line)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Закрыть") { dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction)
                if model.phase == .applied {
                    if !removing {
                        Button(model.connectedProjectID == nil ? "К доске" : "Открыть проект") {
                            if let id = model.connectedProjectID, store.projection?.projects[id] != nil {
                                store.selectedProjectID = id; store.show(id)
                            }
                            store.screen = .board; dismiss()
                        }.buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button(model.isPending ? "Ожидаем…" : (removing ? "Удалить из Kaban" : route.operation == .add ? "Добавить" : "Переподключить")) {
                        Task { await model.submit(); model.observeOutcome(); if model.phase == .applied { await model.refreshDiagnostics() } }
                    }.buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
                }
            }.padding(20)
        }.frame(width: 600).background(theme.window).foregroundStyle(theme.text)
            .onAppear { model.observeOutcome(); identityFocus = model.draft.identity.focus; if model.phase == .applied { Task { await model.refreshDiagnostics() } } }
            .onChange(of: model.phase) { _, _ in
                model.observeOutcome(); identityFocus = model.draft.identity.focus
                if model.phase == .applied { Task { await model.refreshDiagnostics() } }
            }
            .onChange(of: store.connectionState) { _, state in
                if state == .connected, model.phase == .applied { Task { await model.refreshDiagnostics() } }
            }
    }
    private var formHeight: CGFloat {
        if removing { return 220 }
        if model.phase == .applied { return 410 }
        if model.draft.showsIdentity { return 390 }
        if model.formError != nil || model.isPending { return 340 }
        return 270
    }
    private var folderForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("Папка") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("/Users/…/project", text: Binding(get: { model.draft.path }, set: { model.editPath($0) }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).accessibilityLabel("Папка проекта")
                        Button("Выбрать…") { chooseFolder() }.buttonStyle(KabanButtonStyle())
                    }
                    note("Папку и доступ к ней проверит локальная служба.")
                    if let error = store.folderAccess.error { note(error) }
                }
            }
            if route.operation == .add {
                row("Шаблон") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Создать шаблон .kaban/ и закоммитить", isOn: Binding(get: { model.draft.createTemplate }, set: { model.setCreateTemplate($0) }))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                        note("Если пайплайна нет, служба создаст шаблон и закоммитит только .kaban/. Модели настраиваются в пайплайне.")
                    }
                }
                if model.draft.showsIdentity {
                    identityField(.name, title: "Имя", field: model.draft.identity.name)
                    identityField(.email, title: "Почта", field: model.draft.identity.email)
                    row("") { note("Автор сохранится на этом Маке; глобальные настройки git не изменятся.") }
                } else {
                    row("Автор") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Возьмём из настроек git").font(.system(size: 12, weight: .medium))
                            note("Служба прочитает имя и почту в выбранном репозитории. Если автора нет или значение недопустимо, предложим ввести его здесь.")
                        }.padding(12).background(theme.control, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                note("Служба сохранит идентификатор проекта, задачи и историю и проверит репозиторий по новому пути.")
            }
            if !store.can(route.operation == .add ? .addProject : .relinkProject) {
                note(store.unavailableReason(route.operation == .add ? .addProject : .relinkProject))
            }
        }.disabled(model.isPending)
    }
    private func identityField(_ fieldID: IdentityField, title: String, field: IdentityFieldDraft) -> some View {
        row(title) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TextField(title, text: Binding(get: { fieldID == .name ? model.draft.identity.name.value : model.draft.identity.email.value }, set: { model.editIdentity(fieldID, value: $0) }))
                        .textFieldStyle(.roundedBorder).focused($identityFocus, equals: fieldID).font(.system(size: 12)).accessibilityLabel(title)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(field.highlighted ? theme.status("waiting").0 : .clear, lineWidth: 1.5))
                    if field.fromGitSettings { Text("из настроек git").font(.system(size: 10)).foregroundStyle(theme.faint).fixedSize() }
                }
                if let caption = field.caption { Text(caption).font(.system(size: 11)).foregroundStyle(theme.status("waiting").2).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private var identityRefusal: Bool {
        if case .rejected(let error) = model.phase { return error.code == CommandError.identityRequiredCode }; return false
    }
    private func refusal(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.status("waiting").2)
            VStack(alignment: .leading, spacing: 5) {
                Text(error).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.status("waiting").2)
                if let clarification = model.draft.identity.clarification, identityRefusal { note(clarification) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.status("waiting").0.opacity(0.4), lineWidth: 0.5))
    }
    private var removalExplanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let id = route.operation.projectID, let project = store.projection?.projects[id] {
                Text(project.name).font(.system(size: 15, weight: .semibold))
                Text(project.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            note("Незавершённые задачи будут отменены, текущие запуски — остановлены. Служба сохранит историю и отправит ветки задач на архивацию. Папка репозитория и ваши изменения не удаляются.")
            note("Чтобы только убрать дорожку, используйте «Скрыть с доски» в меню проекта.")
            if !store.can(.removeProject) { note(store.unavailableReason(.removeProject)) }
        }
    }
    @ViewBuilder private var result: some View {
        Label(removing ? "Проект удалён из списка" : "Проект подключён", systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.status("done").2)
        if !removing, let id = model.connectedProjectID, let project = store.projection?.projects[id] {
            Text(project.name).font(.system(size: 17, weight: .semibold))
            row("Ветка") { Text(project.baseBranch).font(.system(size: 12, design: .monospaced)) }
            if model.isReading { ProgressView().controlSize(.small) }
            if let branches = model.branches { row("Ветки") { note(branches.isEmpty ? "Список пуст" : branches.joined(separator: ", ")) } }
            if let error = model.branchesError { note(error) }
            if let gates = model.gates { row("Гейты") { note(gates.isEmpty ? "Команды не найдены" : gates.joined(separator: "\n")) } }
            if let error = model.gatesError { note(error) }
            if let error = model.environmentError { note(error) }
            if let environment = model.environment { note(environment.authOK && environment.cursorAgentPath != nil && environment.version != nil && environment.gitVersion != nil && environment.sandboxOK ? "Cursor готов по последней проверке службы." : "Cursor пока недоступен. Задачи можно хранить в Backlog.") }
            if let pipeline = store.projection?.pipelines[id], !pipeline.isValid {
                Label("Для запусков настройте пайплайн. Backlog доступен.", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(theme.status("waiting").2)
                ForEach(Array(pipeline.issues.enumerated()), id: \.offset) { _, issue in note(issue.message) }
            }
            if model.diagnosticsStale, model.branches != nil || model.gates != nil || model.environment != nil { note("Показана последняя проверка; часть данных недоступна или устарела.") }
            Button("Проверить снова") { Task { await model.refreshDiagnostics() } }.buttonStyle(KabanButtonStyle()).disabled(model.isReading || !store.canSend)
        }
    }
    private var pendingText: String? {
        switch model.phase { case .sending: "Подключаем проект…"; case .deliveryUncertain: "Исход отправки неизвестен. Проверим прежнюю команду после подключения."; case .awaitingEvent: "Ждём подтверждения от службы Kaban."; default: nil }
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.secondary).frame(width: 65, alignment: .leading).padding(.top, 4)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func note(_ value: String) -> some View { Text(value).font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Выбрать"; panel.message = "Выберите папку git-репозитория. Служба проверит доступ и конфигурацию."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.folderAccess.remember(url); model.editPath(url.path)
    }
}
