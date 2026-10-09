import AppKit
import SwiftUI
import KabanProtocol
import KabanBoardCore

struct ProjectMCPView: View {
    @Bindable var settings: ProjectMCPStore
    @Bindable var board: BoardStore
    let theme: KabanTheme
    let close: () -> Void
    let editStage: (StageID) -> Void
    @State private var width: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) { Image(systemName: "chevron.left") }.buttonStyle(KabanButtonStyle()).help("Назад к настройкам")
                    .keyboardShortcut(.escape, modifiers: [])
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP проекта").font(.system(size: 21, weight: .bold))
                    Text(settings.project?.name ?? settings.projectID.rawValue).font(.system(size: 12)).foregroundStyle(theme.secondary)
                }
                Spacer()
                Button("Перечитать список") { Task { await settings.load() } }.buttonStyle(KabanButtonStyle())
                    .disabled(settings.catalogState == .loading)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let issue = settings.project?.mcpIssue {
                        VStack(alignment: .leading, spacing: 9) {
                            Label(issue.kind == .unexpected ? "CLI видит сервер «\(issue.name)» вне конфига Kaban" : "MCP не удалось проверить: \(issue.name)", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange).textSelection(.enabled)
                            Text("Проверьте разрешения и конфиги. Блокировка сохраняется до успешной проверки MCP службой.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                            Button("Перепроверить проект") { Task { await board.recheckProject(settings.projectID); await settings.load() } }
                                .buttonStyle(KabanButtonStyle()).disabled(!board.canRecheck(settings.projectID))
                            if let receipt = board.recheckRecord(settings.projectID), receipt.phase == .applied {
                                Text("Папка и пайплайн перепроверены. Результат MCP показан выше.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if width > 850 {
                        HStack(alignment: .top, spacing: 20) { permissions.frame(maxWidth: .infinity); assignments.frame(width: 330) }
                    } else { permissions; assignments }
                    Text("Разрешайте только нужные серверы: их инструменты могут выполнять действия во внешних системах.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                    Text("Список хранится только на этом Маке, в базе службы. Kaban собирает конфиг на каждый запуск; лишний сервер в CLI блокирует запуск. Личный .cursor/mcp.json не меняется.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.foregroundStyle(theme.text).background(theme.window)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onAppear { Task { await settings.load() } }
            .onChange(of: settings.session.canSend) { _, connected in if connected { Task { await settings.load() } } }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Сервер доски") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("kaban").font(.system(size: 13, weight: .semibold)); Text("Нужен Kaban · включён всегда").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                    Spacer(); Image(systemName: "lock.fill").foregroundStyle(theme.secondary)
                    MCPPermissionSwitch(isOn: .constant(true), enabled: false, label: "kaban · включён всегда", identifier: "mcp-kaban-locked")
                }
            }
            switch settings.catalogState {
            case .unknown, .loading: HStack { ProgressView().controlSize(.small); Text("Читаем серверы у службы Kaban…").font(.system(size: 12)) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                Button("Повторить чтение") { Task { await settings.load() } }.buttonStyle(KabanButtonStyle())
            case .loaded(let catalog):
                if settings.allowed == nil { Text("Служба не передала разрешения MCP. Изменение недоступно.").font(.system(size: 12)).foregroundStyle(.orange) }
                sourceGroup("Серверы проекта", subtitle: ".cursor/mcp.json", source: .project, catalog: catalog)
                sourceGroup("Личные серверы", subtitle: "~/.cursor/mcp.json", source: .personal, catalog: catalog)
                if !settings.missingAllowed.isEmpty {
                    card("Отсутствующие разрешения") {
                        Text(settings.missingAllowed.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text("Эти имена разрешены, но больше не найдены в конфигурации. Выбор стадий сохраняется.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                        Button("Удалить отсутствующие разрешения") { Task { await settings.removeMissingPermissions() } }.buttonStyle(KabanButtonStyle()).disabled(!settings.canEdit)
                    }
                }
            }
            if settings.pending { Text("Ожидаем подтверждение службы…").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            if let error = settings.error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange) }
        }
    }
    private func sourceGroup(_ title: String, subtitle: String, source: McpServerRef.Source, catalog: [McpServerRef]) -> some View {
        card(title) {
            Text(subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary)
            let entries = catalog.filter { $0.source == source }
            if entries.isEmpty { Text("В этом источнике серверов нет.").font(.system(size: 12)).foregroundStyle(theme.secondary) }
            ForEach(entries, id: \.self) { entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.name).font(.system(size: 13, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        let stages = settings.selectedStages(entry.name)
                        if !stages.isEmpty { Text("Выбран в стадиях: " + stages.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true) }
                        if catalog.filter({ $0.name == entry.name }).count > 1 { Text("Имя есть в двух источниках. Разрешение общее; Kaban проверит конфликт перед запуском.").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        if entry.name == "kaban" { Text("Системное имя: внешний конфиг не заменяет сервер доски.").font(.system(size: 11)).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 8)
                    MCPPermissionSwitch(isOn: Binding(get: { settings.allowed?.contains(entry.name) == true }, set: { value in Task { await settings.setAllowed(entry.name, enabled: value) } }),
                        enabled: settings.canEdit && entry.name != "kaban", label: "Разрешить " + entry.name, identifier: "mcp-allow-" + source.rawValue + "-" + entry.name)
                }.padding(.vertical, 5)
            }
        }
    }
    private var assignments: some View {
        card("MCP в стадиях") {
            Text("Сохранённый выбор. Измените серверы в редакторе стадии, чтобы применить их к будущим запускам.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            let stages = board.projection?.pipelines[settings.projectID]?.stages.filter { $0.kind == .agent } ?? []
            if stages.isEmpty { Text("Стадий с агентом пока нет.").font(.system(size: 12)).foregroundStyle(theme.secondary) }
            ForEach(stages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(stage.name).font(.system(size: 13, weight: .semibold)); Spacer(); Button("Настроить") { editStage(stage.id) }.buttonStyle(KabanButtonStyle(compact: true)) }
                    Text("Выбрано: " + (stage.mcp?.joined(separator: ", ") ?? "нет данных")).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Набор по разрешениям: " + (stage.effectiveMcp?.joined(separator: ", ") ?? "нет данных")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 5)
            }
            Text("Доступность и совпадение серверов CLI проверяются перед запуском.").font(.system(size: 11)).foregroundStyle(theme.secondary)
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 13, weight: .semibold)); Divider(); content() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 0.5))
    }
}

struct MCPPermissionSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    let enabled: Bool
    let label: String
    let identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.target = context.coordinator; control.action = #selector(Coordinator.changed(_:))
        return control
    }
    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.owner = self
        control.state = isOn ? .on : .off; control.isEnabled = enabled
        control.identifier = .init(identifier)
        control.setAccessibilityIdentifier(identifier); control.setAccessibilityLabel(label)
    }
    @MainActor final class Coordinator: NSObject {
        var owner: MCPPermissionSwitch
        init(_ owner: MCPPermissionSwitch) { self.owner = owner }
        @objc func changed(_ control: NSSwitch) {
            owner.isOn = control.state == .on
            control.state = owner.isOn ? .on : .off
        }
    }
}
