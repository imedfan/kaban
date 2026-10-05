import SwiftUI
import KabanProtocol
import KabanBoardCore

/// Spacing, surfaces and semantic colours from design/tokens.css.
enum DesignSystem {
    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 14
    static func color(_ tone: CardPresentation.Tone) -> Color {
        ReferenceTheme(dark: false).status(tone.rawValue).0
    }
    static func projectCount(_ count: Int) -> String {
        let last = count % 10, pair = count % 100
        let noun = last == 1 && pair != 11 ? "проект" : (2...4).contains(last) && !(12...14).contains(pair) ? "проекта" : "проектов"
        return "\(count) \(noun)"
    }
    static func symbol(_ stage: StageSummary) -> String {
        if let icon = stage.display.icon { return icon }
        switch stage.kind {
        case .queue: return "tray"
        case .agent: return stage.readOnly ? "eye" : "hammer"
        case .gate: return "checklist"
        case .human: return "person.badge.shield.checkmark"
        case .merge: return "arrow.triangle.merge"
        case .terminal: return "checkmark.circle"
        }
    }
    static func tone(_ stage: StageSummary) -> String {
        switch stage.kind {
        case .queue: "queued"
        case .agent: "running"
        case .gate: "gating"
        case .human: "review"
        case .merge: "conflict"
        case .terminal: "done"
        }
    }
}

/// Product controls have a stable size; AppKit still owns window chrome and menus.
struct KabanButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let theme = ReferenceTheme(dark: scheme == .dark)
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 32)
            .foregroundStyle(primary ? Color.white : theme.text)
            .background(primary ? theme.accent : theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.clear : theme.strongLine, lineWidth: 0.5))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct KabanIconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(ReferenceTheme(dark: scheme == .dark).control, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct KabanSegments<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(Selection, String)]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = ReferenceTheme(dark: scheme == .dark)
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button { selection = option.0 } label: {
                    Text(option.1).font(.system(size: 11, weight: selection == option.0 ? .semibold : .medium))
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .foregroundStyle(selection == option.0 ? theme.text : theme.secondary)
                        .background(selection == option.0 ? theme.card : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option.0 ? [.isSelected] : [])
            }
        }.padding(3).background(theme.control, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Native presentation of common task Markdown; the editor retains the exact source.
struct TaskMarkdownView: View {
    let source: String
    @Environment(\.colorScheme) private var scheme
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let heading: Int
        let code: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = []
        var inCode = false
        var codeLines: [String] = []
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("```") {
                if inCode { result.append(.init(id: index, text: codeLines.joined(separator: "\n"), heading: 0, code: true)); codeLines = [] }
                inCode.toggle(); continue
            }
            if inCode { codeLines.append(line); continue }
            let heading = line.prefix(while: { $0 == "#" }).count
            let isHeading = heading > 0 && heading <= 6 && line.dropFirst(heading).hasPrefix(" ")
            if !line.isEmpty { result.append(.init(id: index, text: isHeading ? String(line.dropFirst(heading + 1)) : line, heading: isHeading ? heading : 0, code: false)) }
        }
        if !codeLines.isEmpty { result.append(.init(id: Int.max, text: codeLines.joined(separator: "\n"), heading: 0, code: true)) }
        return result
    }
    var body: some View {
        let theme = ReferenceTheme(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                if block.code {
                    Text(block.text).font(.system(size: 11, design: .monospaced)).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(theme.control, in: RoundedRectangle(cornerRadius: 8))
                } else if block.heading > 0 {
                    Text(block.text).font(.system(size: block.heading == 1 ? 17 : 13, weight: .semibold)).padding(.top, 8)
                } else {
                    let bullet = block.text.hasPrefix("- ") || block.text.hasPrefix("* ")
                    HStack(alignment: .top, spacing: 7) {
                        if bullet { Text("•").foregroundStyle(theme.faint) }
                        Text(inline(bullet ? String(block.text.dropFirst(2)) : block.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 12)).lineSpacing(3)
                }
            }
        }.textSelection(.enabled)
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
