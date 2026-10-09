import SwiftUI
import KabanProtocol
import KabanBoardCore

struct StageMCPPicker: View {
    @Bindable var settings: ProjectMCPStore
    @Bindable var editor: PipelineEditorStore
    let stageID: String
    let path: String
    let theme: KabanTheme
    let openMCP: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("MCP стадии").font(.system(size: 13, weight: .semibold)); Spacer(); Button("Открыть MCP проекта", action: openMCP).buttonStyle(KabanButtonStyle(compact: true)) }
            if let selected = editor.document.stringList(path), editor.document.canEdit(path) {
                HStack { Text("kaban · нужен Kaban"); Spacer(); MCPPermissionSwitch(isOn: .constant(true), enabled: false, label: "kaban · нужен Kaban", identifier: "stage-mcp-kaban-locked").fixedSize() }
                if let allowed = settings.allowed {
                    let names = Set(allowed + selected).subtracting(["kaban"]).sorted()
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(name).fixedSize(horizontal: false, vertical: true); Spacer()
                                MCPPermissionSwitch(isOn: Binding(get: { editor.document.stringList(path)?.contains(name) == true }, set: { editor.setMCPServer(name, path: path, selected: $0) }),
                                    enabled: !editor.isPending && (selected.contains(name) || (allowed.contains(name) && settings.catalog?.contains { $0.name == name } == true)),
                                    label: name, identifier: "stage-mcp-" + name).fixedSize()
                            }
                            if selected.contains(name) && !allowed.contains(name) { Text("Выключен в MCP проекта — не подключится").font(.system(size: 11)).foregroundStyle(.orange) }
                            else if let catalog = settings.catalog, !catalog.contains(where: { $0.name == name }) { Text("Не найден в конфигурации; Kaban проверит доступность перед запуском.").font(.system(size: 11)).foregroundStyle(.orange) }
                        }
                    }
                } else { Text("Разрешения MCP не переданы службой.").font(.system(size: 12)).foregroundStyle(.orange) }
                switch settings.catalogState {
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
                case .unknown, .loading: Text("Список MCP читается у службы…").font(.system(size: 11)).foregroundStyle(theme.secondary)
                case .loaded: EmptyView()
                }
                if let stage = editor.lastResolved?.stages.first(where: { $0.id.rawValue == stageID }), let names = stage.effectiveMcp {
                    Text("По последней проверке службы: " + names.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary).textSelection(.enabled)
                }
                Text("Выбор действует с новых запусков. Выключенные серверы остаются в YAML и дают предупреждение.").font(.system(size: 11)).foregroundStyle(theme.secondary)
            } else { Text("MCP использует сложную YAML-конструкцию. Откройте исходный YAML для точного редактирования.").font(.system(size: 12)).foregroundStyle(theme.secondary) }
        }.padding(14).background(theme.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            .onAppear { Task { await settings.load() } }
            .onChange(of: settings.session.canSend) { _, connected in if connected { Task { await settings.load() } } }
    }
}
