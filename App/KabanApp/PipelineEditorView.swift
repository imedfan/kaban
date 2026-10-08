import SwiftUI
import KabanProtocol
import KabanBoardCore

struct PipelineEditorView: View {
    @Bindable var editor: PipelineEditorStore
    let projectName: String
    let theme: ReferenceTheme
    let close: () -> Void
    @State private var selectedStage: String?
    @State private var section = "Основное"
    @State private var yaml = false
    @State private var newID = ""
    @State private var newKind = "agent"
    @State private var reloadConfirmation = false
    private let sections = ["Основное", "Исполнитель", "Переходы", "Надёжность", "Хуки", "Git"]
    private var stage: PipelineTextDocument.Stage? {
        editor.document.stages.first { $0.id == selectedStage } ?? editor.document.stages.first
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editor.source == nil {
                VStack(spacing: 14) {
                    if editor.loading { ProgressView() }
                    Text(editor.error ?? "Чтение точного pipeline.yaml…").foregroundStyle(theme.secondary)
                    Button("Повторить чтение") { Task { await editor.readSource() } }.disabled(editor.loading)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    navigation.frame(width: 175)
                    Divider()
                    VStack(spacing: 12) {
                        status
                        if yaml {
                            TextEditor(text: .init(get: { editor.content }, set: { editor.edit($0) }))
                                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                                .padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("pipeline-yaml").accessibilityLabel("Исходный YAML пайплайна")
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    if !editor.document.supportsForms {
                                        Text("Этот YAML использует сложные конструкции. Для сохранения исходного текста откройте YAML.").font(.callout).foregroundStyle(theme.secondary)
                                    }
                                    if selectedStage == "__board" { projectForm }
                                    else if let stage { stageForm(stage) }
                                    else { Text("Стадий пока нет. Добавьте стадию или откройте YAML.").foregroundStyle(theme.secondary) }
                                    validationIssues
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Изменения действуют с новых запусков. Commit .kaban/ выполняет служба Kaban.")
                Spacer()
                Text(editor.hasDraftChanges ? "Черновик изменён" : editor.isApplied ? "Версия применена" : "Точный исходный текст")
            }.font(.system(size: 11)).foregroundStyle(theme.secondary).padding(12)
        }.foregroundStyle(theme.text).background(theme.window)
            .task {
                await editor.loadIfNeeded()
                if BoardQA.isActive {
                    selectedStage = BoardQA.argument("--qa-pipeline-stage")
                    section = BoardQA.argument("--qa-pipeline-section") ?? "Основное"
                    yaml = BoardQA.argument("--qa-pipeline-yaml") == "yes"
                }
            }
            .onChange(of: editor.connectionAvailable) { _, available in
                Task {
                    if available && editor.source == nil { await editor.readSource() }
                    else if available && editor.isApplied { await editor.confirmApplied() }
                    else { await editor.validate() }
                }
            }
            .onChange(of: editor.isApplied) { _, applied in if applied { Task { await editor.confirmApplied() } } }
            .confirmationDialog("Заменить черновик текущим файлом?", isPresented: $reloadConfirmation) {
                Button("Перезагрузить файл", role: .destructive) { Task { await editor.readSource(replaceDraft: true) } }
            } message: { Text("Несохранённый ввод будет заменён. Для сохранения ввода выберите новую базу после сравнения YAML.") }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) { Image(systemName: "chevron.left") }.help("Настройки проекта")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(stage?.name ?? "Пайплайн") · настройки").font(.system(size: 17, weight: .semibold))
                    .lineLimit(2).help(stage?.name ?? "Пайплайн")
                Text(projectName + " · .kaban/pipeline.yaml").font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(yaml ? "Формы" : "pipeline.yaml") { yaml.toggle() }.buttonStyle(KabanButtonStyle())
            Menu("Перечитать") {
                Button("Проверить файл, сохранив ввод") { Task { await editor.readSource() } }
                Button("Заменить черновик файлом…") { reloadConfirmation = true }
            }.disabled(editor.isPending || editor.loading)
            Button("Применить") { Task { await editor.apply() } }
                .buttonStyle(KabanButtonStyle(primary: true)).disabled(!editor.canApply)
                .keyboardShortcut(.return, modifiers: [.command]).accessibilityIdentifier("pipeline-apply")
        }.padding(16)
    }
    private var navigation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Стадии пайплайна").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
                ForEach(editor.document.stages, id: \.index) { item in
                    Button { selectedStage = item.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(item.name).lineLimit(2); Text(item.kind).font(.system(size: 10)).foregroundStyle(theme.secondary) }
                            Spacer(minLength: 4)
                            if editor.issues.contains(where: { $0.stageId?.rawValue == item.id }) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(stage?.id == item.id && selectedStage != "__board" ? theme.control : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Divider().padding(.vertical, 6)
                Button("Лимиты и проект") { selectedStage = "__board" }.buttonStyle(KabanButtonStyle(compact: true))
                TextField("ID новой стадии", text: $newID).textFieldStyle(.roundedBorder).accessibilityLabel("ID новой стадии")
                Picker("Тип", selection: $newKind) { ForEach(StageKind.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden()
                Button("Добавить стадию") { editor.addStage(id: newID, kind: newKind); selectedStage = newID; newID = "" }
                    .disabled(newID.isEmpty || !editor.document.supportsForms)
            }.font(.system(size: 12)).padding(12)
        }
    }
    @ViewBuilder private var status: some View {
        if let source = editor.source {
            VStack(alignment: .leading, spacing: 4) {
                Text("versionHash: " + (source.baseVersionHash ?? "Нет валидной версии"))
                Text("sourceHash: " + source.baseSourceHash)
                Text("draft: " + (editor.draft?.contentHash ?? ""))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if source.hasWorkingChanges { notice("Есть неприменённые изменения рабочего файла .kaban/.") }
        }
        if editor.baseChanged { notice("Committed версия изменилась. Перечитайте файл, сохранив ввод.") }
        if let changed = editor.changedSource {
            VStack(alignment: .leading, spacing: 8) {
                notice("Файл изменён другим редактором. Ваш ввод сохранён.")
                DisclosureGroup("Текущий рабочий YAML для сравнения") {
                    ScrollView { Text(changed.workingContent ?? "Файл отсутствует").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
                }
                HStack {
                    Button("Сохранить мой ввод на новой базе") { Task { await editor.keepDraftOnChangedSource() } }
                    Button("Перезагрузить…") { reloadConfirmation = true }
                }
            }.font(.system(size: 11))
        }
        if let error = editor.error { notice(error) }
        switch editor.validation {
        case .idle: Text("Проверка ожидает изменения").font(.caption).foregroundStyle(theme.secondary)
        case .checking: HStack { ProgressView().controlSize(.small); Text("Проверка службой Kaban…").font(.caption) }
        case .unavailable(let reason): notice(reason)
        case .checked: Text("\(editor.issues.filter { $0.severity == .error }.count) ошибок · \(editor.issues.filter { $0.severity == .warning }.count) предупреждений").font(.caption).foregroundStyle(editor.canApply ? theme.secondary : .orange)
        }
        if let phase = editor.receipt?.phase {
            Text(phase == .applied ? "Применение подтверждено службой Kaban" : editor.isPending ? "Ожидаем подтверждение применения" : "Команда завершилась с отказом; черновик сохранён")
                .font(.caption).foregroundStyle(theme.secondary)
        }
    }
    private func stageForm(_ item: PipelineTextDocument.Stage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) { ForEach(sections, id: \.self) { name in Button(name) { section = name }.buttonStyle(KabanButtonStyle(primary: section == name, compact: true)) } }
            }.scrollIndicators(.hidden)
            let p = "stages[\(item.index)]"
            if section == "Основное" { generalCards(item, path: p) }
            else { card(section) {
                switch section {
                case "Исполнитель":
                    if item.kind == "agent" {
                        field("Харнес", p + ".agent.harness", quoted: true)
                        field("Модель", p + ".agent.model", quoted: true)
                        Text("Укажите явный ID модели. Служба проверяет обязательность и запрещает Auto.").font(.caption).foregroundStyle(theme.secondary)
                        field("Скилл (путь)", p + ".agent.skill", quoted: true)
                        choice("Права", p + ".agent.permissions", ["write", "read-only"])
                        choice("Рабочая копия", p + ".agent.workspace", ["task", "fresh-readonly"])
                        field("MCP (YAML)", p + ".agent.mcp")
                        Text("Окружение agent.env доступно в исходном YAML. Секреты не вставляйте в файл.").font(.caption).foregroundStyle(theme.secondary)
                    } else { Text("У этой стадии нет агента.") }
                    if ["agent", "human"].contains(item.kind) { field("Вход (YAML)", p + ".inputs") }
                    if ["agent", "gate", "merge"].contains(item.kind) { field("Гейты (YAML)", p + ".gates") }
                case "Переходы":
                    if item.kind != "terminal" { field("При успехе", p + ".on_success", quoted: true) }
                    if item.kind == "agent" {
                        ForEach(editor.document.returnIndices(stage: item.index), id: \.self) { index in
                            field("Цель возврата \(index + 1)", p + ".returns_to[\(index)].stage", quoted: true)
                            field("Лимит возвратов \(index + 1)", p + ".returns_to[\(index)].limit")
                        }
                        Text("Добавление и удаление целей возврата доступно в исходном YAML.").font(.caption).foregroundStyle(theme.secondary)
                    }
                    if item.kind == "gate" { field("При красном гейте", p + ".on_fail.stage", quoted: true); field("Лимит возвратов при красном гейте", p + ".on_fail.limit") }
                    if item.kind == "merge" { field("При конфликте", p + ".on_conflict.stage", quoted: true); field("Лимит возвратов при конфликте", p + ".on_conflict.limit") }
                    if let resolved = editor.lastResolved?.stages.first(where: { $0.id.rawValue == item.id }) {
                        Text("Цели по проверке службы: " + ([resolved.onFail?.stage, resolved.onConflict?.stage].compactMap { $0?.rawValue } + resolved.returnsTo.map { $0.stage.rawValue }).joined(separator: ", ")).font(.caption).foregroundStyle(theme.secondary)
                    }
                case "Надёжность":
                    if ["agent", "gate"].contains(item.kind) {
                        field("Максимум попыток", p + ".retry.max_attempts")
                        field("Паузы перед повторами (YAML)", p + ".retry.backoff")
                        field("Таймаут зависания", p + ".timeouts.stall", quoted: true)
                        field("Общий таймаут стадии", p + ".timeouts.wall", quoted: true)
                    } else { Text("Для этого типа надёжность задаёт служба.") }
                case "Хуки":
                    field("На входе", p + ".hooks.on_enter", quoted: true)
                    field("На выходе", p + ".hooks.on_exit", quoted: true)
                    field("Уведомления (YAML)", p + ".notify")
                default:
                    if item.kind == "agent" {
                        field("Разрешить дополнительно (YAML)", p + ".git.extend")
                        field("Запретить (YAML)", p + ".git.deny")
                        field("Условие разрешений", p + ".git.when", quoted: true)
                        policy(editor.lastResolved?.stages.first { $0.id.rawValue == item.id }?.gitPolicy)
                    } else { Text("У этой стадии нет переопределений git агента.") }
                }
            } }
            let occupied = editor.activeTaskCount(stage: item.id)
            HStack {
                Button("Удалить стадию", role: .destructive) { editor.removeStage(index: item.index, id: item.id) }
                    .disabled(occupied > 0 || !editor.document.supportsForms || editor.isPending)
                if occupied > 0 { Text("Сначала перенесите \(occupied) задач").font(.caption).foregroundStyle(theme.secondary) }
            }
        }
    }
    private func generalCards(_ item: PipelineTextDocument.Stage, path p: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), alignment: .top)], alignment: .leading, spacing: 14) {
            card("Идентичность и вид") {
                LabeledContent("ID", value: item.id)
                field("Имя", p + ".name", quoted: true)
                choice("Тип", p + ".kind", StageKind.allCases.map(\.rawValue))
                field("Иконка", p + ".display.icon", quoted: true)
                field("Цвет", p + ".display.color", quoted: true)
                field("Порядок на доске", p + ".display.order")
                choice("Свёрнут", p + ".display.collapsed", ["false", "true"])
                choice("Скрыт", p + ".display.hidden", ["false", "true"])
                Text("Порядок на доске не меняет переходы on_success.").font(.caption).foregroundStyle(theme.secondary)
            }
            if ["agent", "gate", "human"].contains(item.kind) {
                card("Пропускная способность") {
                    field("WIP-лимит", p + ".wip")
                    field("Приоритет (YAML)", p + ".priority")
                    Text("Снижение WIP не прерывает текущие задачи. Новые запускаются в пределах принятого лимита.").font(.caption).foregroundStyle(theme.secondary)
                }
            }
        }
    }
    private var projectForm: some View {
        VStack(spacing: 14) {
            card("Лимиты пайплайна") {
                field("Версия формата", "version")
                field("Общий лимит возвратов", "board.bounce_limit_total")
                field("Лимит задач в ожидании человека", "board.max_waiting_human")
                field("Лимит запусков на задачу", "board.max_runs_per_task")
            }
            card("Рабочая копия и git проекта") {
                field("Подготовленные пути (YAML)", "workspace.warm_paths")
                field("При создании клона", "workspace.on_create", quoted: true)
                choice("Git-пресет", "git.preset", GitPreset.allCases.map(\.rawValue))
                field("Разрешено (YAML)", "git.allow")
                field("Запрещено (YAML)", "git.deny")
                policy(editor.lastResolved?.projectGitPolicy)
            }
        }
    }
    private func field(_ label: String, _ path: String, quoted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).frame(width: 140, alignment: .leading)
                TextField("Не задано", text: .init(get: { editor.document.value(path) ?? "" }, set: { editor.patch(path, value: $0, quoted: quoted) }))
                    .textFieldStyle(.roundedBorder).disabled(!editor.document.canEdit(path))
                    .accessibilityIdentifier("pipeline-" + path).accessibilityLabel(label)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(fieldIssues(path).contains { $0.severity == .error } ? .orange : fieldIssues(path).isEmpty ? .clear : .yellow, lineWidth: 1))
            }
            if !editor.document.canEdit(path) { Text("Эта конструкция доступна в YAML").font(.caption).foregroundStyle(theme.secondary) }
            ForEach(Array(fieldIssues(path).enumerated()), id: \.offset) { _, issue in Text(issueText(issue)).font(.caption).foregroundStyle(issue.severity == .error ? .orange : .yellow) }
        }.font(.system(size: 12))
    }
    private func choice(_ label: String, _ path: String, _ values: [String]) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
            Picker(label, selection: Binding(get: { editor.document.value(path) ?? "" }, set: { editor.patch(path, value: $0) })) {
                Text("Не задано").tag("")
                if let value = editor.document.value(path), !values.contains(value), !value.isEmpty { Text(value).tag(value) }
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().disabled(!editor.document.canEdit(path)).accessibilityLabel(label)
        }.font(.system(size: 12))
    }
    private func fieldIssues(_ path: String) -> [ValidationIssue] { editor.issues.filter { $0.path == path || $0.path.hasPrefix(path + "[") } }
    private var validationIssues: some View {
        card("Проверка пайплайна") {
            if editor.issues.isEmpty { Text("Нет сообщений для текущего черновика.").foregroundStyle(theme.secondary) }
            ForEach(Array(editor.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 4) {
                    Label(issueText(issue), systemImage: "exclamationmark.triangle").foregroundStyle(issue.severity == .error ? .orange : .yellow)
                    Text(issue.path + " · " + issue.code + " · " + issue.severity.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Ошибки блокируют применение. Предупреждения не блокируют.").font(.caption).foregroundStyle(theme.secondary)
        }
    }
    private func issueText(_ issue: ValidationIssue) -> String {
        ValidationIssueText.render(issue, stageName: editor.lastResolved?.stages.first { $0.id == issue.stageId }?.name)
    }
    @ViewBuilder private func policy(_ policy: EffectiveGitPolicy?) -> some View {
        if let policy {
            Text("Итоговая политика по последней проверке службы").font(.caption).foregroundStyle(theme.secondary)
            Text("Разрешено: " + policy.allowed.map(\.rule).joined(separator: ", ")).font(.caption)
            Text("Запрещено: " + policy.denied.map(\.rule).joined(separator: ", ")).font(.caption)
        } else { Text("Превью итоговой политики пока недоступно").font(.caption).foregroundStyle(theme.secondary) }
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Divider()
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 0.5))
    }
}
