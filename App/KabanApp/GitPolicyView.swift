import SwiftUI
import KabanProtocol
import KabanBoardCore

struct GitPolicyView: View {
    let policy: EffectiveGitPolicy
    let catalog: [String]
    let theme: ReferenceTheme
    var title = "Итоговая политика"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(policy.committer == .daemonOnly ? "Коммитит демон из резюме" : "Агент + страховочный коммит")
                .font(.system(size: 11)).foregroundStyle(theme.secondary)
            if policy.readOnly { Label("Только чтение", systemImage: "eye").font(.system(size: 11)).foregroundStyle(.purple) }
            rules("Разрешено", policy.allowed, denied: false)
            if !policy.conditional.isEmpty {
                Text("По условию").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
                ForEach(Array(policy.conditional.enumerated()), id: \.offset) { _, condition in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("when: return_reason == " + condition.returnReason).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        groups(condition.allowed, denied: false)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            rules("Запрещено", policy.denied, denied: true)
            let outside = GitPolicyPresentation.outsidePreset(catalog: catalog, policy: policy)
            if !outside.isEmpty {
                Text("Нет в пресете (из каталога): " + outside.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            Text("Всё вне каталога — запрещено").font(.system(size: 11)).foregroundStyle(theme.secondary)
            Divider()
            Text("Жёсткие правила · \(policy.hardInvariants.count)").font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(Array(policy.hardInvariants.enumerated()), id: \.offset) { _, id in
                    HardInvariantTile(id: id, theme: theme)
                }
            }
            Text("Слияние в main делает только демон").font(.system(size: 11)).foregroundStyle(theme.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func rules(_ title: String, _ rules: [GitRule], denied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
            if rules.isEmpty { Text("Нет правил").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            groups(rules, denied: denied)
        }
    }
    private func groups(_ rules: [GitRule], denied: Bool) -> some View {
        ForEach(Array(GitPolicyPresentation.groups(rules).enumerated()), id: \.offset) { _, group in
            HStack(alignment: .top, spacing: 10) {
                Text(group.rules.joined(separator: " · ")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if let label = GitPolicyPresentation.label(source: group.source, denied: denied, readOnly: policy.readOnly) {
                    Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(group.source == .stage ? (denied ? Color.purple : Color.blue) : theme.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(theme.control, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct HardInvariantTile: View {
    let id: String
    let theme: ReferenceTheme
    @State private var showDetail = false
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock.fill").foregroundStyle(theme.secondary)
            if let text = GitPolicyPresentation.invariant(id) {
                Text(text.title).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Button { showDetail = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help(text.detail).accessibilityLabel(text.title + ": подробности")
                    .popover(isPresented: $showDetail) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(text.title, systemImage: "lock.fill").font(.headline)
                            Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary)
                            Text(text.detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Button("Закрыть") { showDetail = false }.keyboardShortcut(.escape, modifiers: [])
                        }.padding(18).frame(width: 380).foregroundStyle(theme.text).background(theme.card)
                    }
            } else { Text(id).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
        }.font(.system(size: 11)).padding(9).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                theme.control
                Canvas { context, size in
                    var path = Path()
                    for x in stride(from: -size.height, through: size.width, by: 14) {
                        path.move(to: .init(x: x, y: size.height)); path.addLine(to: .init(x: x + size.height, y: 0))
                    }
                    context.stroke(path, with: .color(theme.line.opacity(0.35)), lineWidth: 6)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line, lineWidth: 0.5))
            .accessibilityElement(children: .contain)
    }
}
