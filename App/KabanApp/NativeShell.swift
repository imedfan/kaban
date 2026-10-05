import SwiftUI

/// Standard macOS navigation, toolbar and inspector; the board is product-specific content.
struct NativeShell: View {
    @Bindable var demo: ReferenceDemo
    @Environment(\.colorScheme) private var colorScheme
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var boardSelection = "board"
    private var theme: ReferenceTheme { .init(dark: colorScheme == .dark) }
    private var settings: Bool { !["board", "mascots", "cards"].contains(demo.route) }
    private var selection: Binding<String?> {
        Binding(get: { settings ? demo.route : boardSelection }, set: { value in
            guard let value else { return }
            if value.hasPrefix("project:") {
                let project = String(value.dropFirst(8))
                demo.selectedProject = project
                demo.showProject(project)
                demo.route = "board"
                boardSelection = value
            } else if ["board", "waiting", "incidents"].contains(value) {
                demo.route = "board"
                boardSelection = value
                demo.selected = value == "waiting" ? demo.tasks.first { ["waiting", "review", "suspicious"].contains($0.status) }?.id : value == "incidents" ? demo.tasks.first { $0.status == "incident" }?.id : nil
            } else {
                demo.openSettings(value, project: demo.selectedProject)
            }
        })
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: selection) {
                Section {
                    Label("Доска", systemImage: "rectangle.split.3x1").tag("board")
                    Label("Ждут человека", systemImage: "hand.raised").badge(demo.waitingCount).tag("waiting")
                    Label("Инциденты", systemImage: "exclamationmark.triangle").badge(demo.incidentCount).tag("incidents")
                }
                Section("Проекты") {
                    ForEach(demo.projects, id: \.self) { project in
                        HStack {
                            Text(project == "shop-api" ? "🦊" : project == "kaban" ? "🐗" : project == "mobile-app" ? "🐙" : "🦉")
                            VStack(alignment: .leading) {
                                Text(project)
                                Text(project == "shop-api" ? "Ждут решения" : project == "kaban" ? "Настройка пайплайна" : "На этом Маке")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag("project:" + project).draggable(project)
                            .contextMenu {
                                Button("Настройки проекта") { demo.openSettings("project-git", project: project) }
                                Button("Показать на доске") { demo.showProject(project) }
                                Button("Скрыть с доски") { demo.visible.removeAll { $0 == project } }
                            }
                    }
                    Button("Добавить проект", systemImage: "plus") { demo.identityMode = 0; demo.sheet = "add" }
                }
                if settings {
                    Section(demo.selectedProject) {
                        Label("Стадия Dev", systemImage: "hammer").tag("general")
                        Label("Стадия Test", systemImage: "flask").tag("pipeline-invalid")
                        Label("Git проекта", systemImage: "shield").tag("project-git")
                        Label("Git стадии", systemImage: "arrow.triangle.branch").tag("stage-git")
                        Label("MCP для запусков", systemImage: "powerplug").tag("project-mcp")
                        Label("Подозрительные файлы", systemImage: "exclamationmark.shield").tag("suspicious-settings")
                        Label("Автор коммитов", systemImage: "person").tag("identity-settings")
                    }
                }
                Section("Этот Мак") {
                    Label("Квота Cursor", systemImage: "gauge.with.dots.needle.50percent").tag("mac-quota")
                }
            }.listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
                .safeAreaInset(edge: .bottom) {
                    GroupBox("Этот Мак") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Агенты", value: "\(demo.runningCount) / 4")
                            ProgressView("Cm · 46%", value: 0.46).tint(.purple)
                            ProgressView("Om · 100%", value: 1).tint(.orange)
                        }.font(.caption)
                    }.padding(12)
                }
        } detail: {
            Group {
                if settings { NativeSettingsView(demo: demo, kind: demo.route) }
                else if demo.route == "mascots" { ReferenceCardGallery(demo: demo, theme: theme, kind: "cards-suspicious") }
                else { ReferenceBoard(demo: demo, theme: theme, nativeContainer: true) }
            }
            .navigationTitle(settings ? NativeSettingsView.title(for: demo.route) : "Доска")
            .toolbar {
                if settings {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("pipeline.yaml", systemImage: "chevron.left.forwardslash.chevron.right") { demo.sheet = "yaml" }
                        Button("Отменить") { demo.cancelSettings() }
                        Button("Сохранить") { save() }.buttonStyle(.borderedProminent)
                            .disabled(demo.route == "pipeline-invalid" && !demo.pipelineErrors.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .principal) {
                        Picker("Вид доски", selection: $demo.compact) {
                            Label("Дорожки", systemImage: "rectangle.split.3x1").tag(false)
                            Label("По стадиям", systemImage: "square.grid.2x2").tag(true)
                        }.pickerStyle(.segmented).frame(width: 270)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Label("\(demo.runningCount)/4", systemImage: "cpu").help("Работающие агенты")
                        Button("Поиск", systemImage: "magnifyingglass") { demo.sheet = "search" }
                        Button("Уведомления", systemImage: "bell") { demo.sheet = "notifications" }
                        Button(demo.macPaused ? "Продолжить" : "Пауза", systemImage: demo.macPaused ? "play" : "pause") { demo.pauseMac() }
                        Button("Настройки", systemImage: "slider.horizontal.3") { demo.openSettings("general", project: demo.selectedProject) }
                        Button("Задача", systemImage: "plus") { demo.draftTitle = ""; demo.draftBody = ""; demo.sheet = "create" }
                    }
                }
            }
            .inspector(isPresented: Binding(get: { demo.selected != nil && !settings }, set: { if !$0 { demo.selected = nil } })) {
                if let selected = demo.selected {
                    ScrollView {
                        ReferenceDetails(demo: demo, theme: theme, kind: demo.detailKind, selectedTaskID: selected, nativeContainer: true)
                    }.inspectorColumnWidth(min: 440, ideal: 560, max: 700)
                }
            }
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in demo.dark = scheme == .dark }
    }
    private func save() {
        if demo.route == "identity-settings" {
            guard demo.validateIdentity(submitted: true) else { return }
            demo.identities[demo.selectedProject] = (demo.identityName, demo.identityEmail)
        }
        demo.applySettings()
    }
}

struct NativeSettingsView: View {
    @Bindable var demo: ReferenceDemo
    let kind: String
    static func title(for kind: String) -> String {
        switch kind {
        case "general": "Настройки стадии Dev"
        case "pipeline-invalid": "Настройки стадии Test"
        case "stage-git", "stage-git-base": "Git-политика стадии"
        case "project-mcp": "MCP для запусков"
        case "mac-quota": "Квота Cursor"
        case "identity-settings": "Автор коммитов"
        case "suspicious-settings": "Подозрительные файлы"
        default: "Git-политика проекта"
        }
    }
    var body: some View {
        Form {
            switch kind {
            case "project-git", "stage-git", "stage-git-base":
                Section("Git-политика") {
                    Picker("Пресет", selection: $demo.preset) {
                        ForEach(["Строгий", "Стандартный", "Свободный"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.radioGroup)
                    Toggle("Только чтение", isOn: $demo.readonly)
                    Text("Слияние в main выполняет демон. Изменения применяются к следующим запускам.").foregroundStyle(.secondary)
                }
                Section("Переопределения команд") {
                    ForEach(["status", "diff", "log", "show", "add", "commit", "restore --staged", "stash", "rebase", "reset", "cherry-pick", "push"], id: \.self) { command in
                        Picker(command, selection: Binding(get: { demo.stageOverrides[command] ?? "Наследовать" }, set: { demo.stageOverrides[command] = $0; demo.unsaved = true })) {
                            ForEach(["Наследовать", "Разрешить", "Разрешить при условии", "Запретить"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            case "project-mcp":
                Section("Серверы для запусков") {
                    ForEach(["kaban", "figma", "sentry", "jira", "github", "postgres-local", "context7", "filesystem"], id: \.self) { server in
                        Toggle(server, isOn: Binding(get: { demo.mcpServers[server] ?? false }, set: { demo.mcpServers[server] = $0; demo.unsaved = true })).disabled(server == "kaban")
                    }
                }
                Section { Text("kaban подключён всегда. Другие серверы доступны только после включения в проекте.").foregroundStyle(.secondary) }
            case "mac-quota":
                Section("Получение квоты") {
                    Toggle("Получать квоту Cursor", isOn: $demo.quotaConsent)
                    Picker("Интервал", selection: $demo.quotaInterval) {
                        ForEach(["1 мин", "5 мин", "15 мин", "30 мин"], id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Порог Cm · \(Int(demo.quotaThresholdCm))%") { Slider(value: $demo.quotaThresholdCm, in: 0...100, step: 1) }
                    LabeledContent("Порог Om · \(Int(demo.quotaThresholdOm))%") { Slider(value: $demo.quotaThresholdOm, in: 0...100, step: 1) }
                }
                Section("Текущая квота") {
                    ProgressView("Cm · 46%", value: 0.46).tint(.purple)
                    ProgressView("Om · 100%", value: 1).tint(.orange)
                }
            case "identity-settings":
                Section("Автор коммитов проекта") {
                    TextField("Имя", text: $demo.identityName)
                    TextField("Почта", text: $demo.identityEmail)
                    if demo.identityMode > 0 { Text("Укажите непустые имя и почту без переводов строки.").foregroundStyle(.orange) }
                }
            case "suspicious-settings":
                Section("Проверка файлов") {
                    TextField("Шаблоны путей", text: $demo.filePatterns)
                    TextField("Максимальный размер · МБ", text: $demo.maxFileMB)
                    TextField("Исключения", text: $demo.fileAllow)
                }
            default:
                Section("Идентичность и пропускная способность") {
                    TextField("Имя", text: field("Имя", "Разработка"))
                    Stepper("WIP-лимит · \(demo.stageFields["WIP-лимит"] ?? "2")", value: integerField("WIP-лимит", 2), in: 1...16)
                    Stepper("Попыток · \(demo.stageFields["Попыток"] ?? "3")", value: integerField("Попыток", 3), in: 1...20)
                }
                Section("Исполнитель") {
                    Picker("Харнес", selection: field("Харнес", "Cursor CLI")) { Text("Cursor CLI").tag("Cursor CLI") }
                    modelPicker("Dev", selection: field("Модель", "composer-1"))
                    modelPicker("Test", selection: $demo.model)
                    modelPicker("AI Review", selection: $demo.requestedModel)
                    if kind == "pipeline-invalid" && !demo.pipelineErrors.isEmpty {
                        Label("Для Test и AI Review нужна явная модель", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    TextField("Скилл (роль)", text: field("Скилл (роль)", ".kaban/skills/dev.md"))
                }
                Section("Надёжность") {
                    TextField("Таймаут зависания", text: field("Таймаут зависания", "10 мин"))
                    TextField("Общий таймаут", text: field("Общий таймаут", "60 мин"))
                    TextField("Паузы между попытками", text: field("Паузы", "30s, 2m, 5m"))
                }
                Section("Окружение и рабочая копия") {
                    TextField("Рабочая папка", text: field("Рабочая папка", "."))
                    TextField("Переменные", text: field("Переменные", ""))
                    TextField("Секреты", text: field("Секреты", ""))
                }
                Section("Гейты и переходы") {
                    TextField("Команды гейтов", text: field("Гейты", "swift test"))
                    Picker("После успеха", selection: field("После успеха", "Test")) { ForEach(ReferenceDemo.stages, id: \.self) { Text($0).tag($0) } }
                    Picker("Возврат в", selection: field("Возврат в", "Dev")) { ForEach(ReferenceDemo.stages, id: \.self) { Text($0).tag($0) } }
                    TextField("Хуки", text: field("Хуки", ""))
                }
            }
        }.formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .toggleStyle(.checkbox)
    }
    private func field(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { demo.stageFields[key] ?? fallback }, set: { demo.stageFields[key] = $0; demo.unsaved = true })
    }
    private func integerField(_ key: String, _ fallback: Int) -> Binding<Int> {
        Binding(get: { Int(demo.stageFields[key] ?? "") ?? fallback }, set: { demo.stageFields[key] = String($0); demo.unsaved = true })
    }
    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Выберите модель").tag("")
            ForEach(["composer-1", "sonnet-4.5", "opus-4.5", "gpt-5", "auto"], id: \.self) { Text($0).tag($0) }
        }
    }
}

struct NativeAddProjectForm: View {
    @Bindable var demo: ReferenceDemo
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Добавить проект").font(.title2)
            Form {
                Section("Проект") {
                    LabeledContent("Папка") {
                        HStack {
                            TextField("Путь к репозиторию", text: $demo.projectPath)
                            Button("Выбрать…") { Task { await demo.chooseFolder() } }
                        }
                    }
                    Toggle("Создать шаблон .kaban/", isOn: $demo.template)
                }
                Section("Автор коммитов") {
                    TextField("Имя", text: $demo.identityName)
                    TextField("Почта", text: $demo.identityEmail)
                    if demo.identityMode > 0 { Label("Укажите имя и почту автора", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }.formStyle(.grouped).textFieldStyle(.roundedBorder).frame(height: 290)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { demo.sheet = nil }
                Button("Добавить") { demo.addProject() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct NativeReturnForm: View {
    @Bindable var demo: ReferenceDemo
    let merge: Bool
    private var hasNote: Bool { !demo.returnNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Вернуть \(demo.selected ?? "задачу")").font(.title2)
            Form {
                Picker("Стадия", selection: $demo.returnTarget) { Text("Dev").tag("Dev"); Text("Test").tag("Test") }
                Section("Замечание агенту") { TextEditor(text: $demo.returnNote).frame(height: 120) }
                Section { Text(hasNote ? "Файлы остаются помеченными. Агент получит замечание." : "Текущий набор файлов будет принят, задача вернётся без замечания.").foregroundStyle(.secondary) }
            }.formStyle(.grouped).frame(height: 300)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { demo.sheet = nil }
                Button(hasNote ? "Вернуть с замечанием" : "Принять файлы и вернуть") { demo.returnTask(filled: hasNote, merge: merge) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}
