import SwiftUI
import KabanProtocol
import KabanBoardCore

struct GitRuleEditor: View {
    @Bindable var editor: PipelineEditorStore
    let path: String
    let projectPolicy: EffectiveGitPolicy?
    let catalog: [String]
    let theme: ReferenceTheme
    var readOnly = false
    private var isStage: Bool { path.hasPrefix("stages[") }
    private var allowPath: String { path + (isStage ? ".extend" : ".allow") }
    private var denyPath: String { path + ".deny" }
    private var allow: [String]? { editor.document.stringList(allowPath) }
    private var deny: [String]? { editor.document.stringList(denyPath) }
    private var commands: [String] {
        catalog + ((allow ?? []) + (deny ?? [])).filter { !catalog.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Команда").frame(maxWidth: .infinity, alignment: .leading); Text("Проект").frame(width: 110, alignment: .leading); Text(isStage ? "Переопр." : "В проекте").frame(width: 130) }
                .font(.system(size: 10)).foregroundStyle(theme.secondary).padding(.vertical, 7)
            ForEach(commands, id: \.self) { command in
                Divider()
                HStack(alignment: .center, spacing: 8) {
                    Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text(projectState(command)).font(.system(size: 10)).foregroundStyle(theme.secondary).frame(width: 110, alignment: .leading)
                    Picker(command, selection: Binding(get: { choice(command) }, set: { change(command, to: $0) })) {
                        Text(isStage ? "Из проекта" : "Из пресета").tag(PipelineEditorStore.GitRuleEdit.inherit)
                        Text("Разрешить").tag(PipelineEditorStore.GitRuleEdit.allow).disabled(isStage && (readOnly || projectDenies(command)))
                        Text("Запретить").tag(PipelineEditorStore.GitRuleEdit.deny)
                    }.labelsHidden().frame(width: 130).disabled(editor.isPending || allow == nil || deny == nil)
                        .accessibilityLabel(command + " · " + (isStage ? "переопределение стадии" : "правило проекта"))
                }.padding(.vertical, 7)
            }
            if allow == nil || deny == nil { Text("Сложный список сохраняется без изменений. Редактируйте его в YAML.").font(.caption).foregroundStyle(theme.secondary) }
            if isStage { Text("Запрет проекта стадия не снимает. Для extend условие when задаётся отдельно; deny действует всегда.").font(.caption).foregroundStyle(theme.secondary).padding(.top, 10) }
        }
    }
    private func projectDenies(_ command: String) -> Bool { projectPolicy?.denied.contains { $0.rule == command && $0.source == .project } == true }
    private func projectState(_ command: String) -> String {
        guard let policy = projectPolicy else { return "Нет данных" }
        if policy.denied.contains(where: { $0.rule == command }) { return "Запрещено проектом" }
        if policy.allowed.contains(where: { $0.rule == command }) { return "Разрешено" }
        return "Нет в пресете"
    }
    private func choice(_ command: String) -> PipelineEditorStore.GitRuleEdit {
        if deny?.contains(command) == true { return .deny }
        return allow?.contains(command) == true ? .allow : .inherit
    }
    private func change(_ command: String, to choice: PipelineEditorStore.GitRuleEdit) {
        guard !editor.isPending else { return }
        if choice == .allow, isStage && (readOnly || projectDenies(command)) { return }
        editor.setGitRule(command, allowPath: allowPath, denyPath: denyPath, decision: choice)
    }
}
