import AppKit
import SwiftUI
import KabanProtocol

struct MaterialTextRoute: Identifiable {
    let id: String
    let title: String
    let text: String
}
struct MaterialTextSheet: View {
    let route: MaterialTextRoute
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(route.title).font(.headline); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
            MaterialTextView(text: route.text, loading: $loading)
            HStack {
                Text("\(route.text.utf8.count) байт · исходный текст целиком").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView("Загружаем текст…").controlSize(.small) }
            }
        }.padding(20).frame(width: 640, height: 440)
    }
}
struct MaterialTextView: NSViewRepresentable {
    let text: String
    @Binding var loading: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false
        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true; view.usesFindBar = true
        view.isRichText = false; view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = .init(width: 10, height: 10)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.load(text, in: view, loading: $loading)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.cancel() }
    @MainActor final class Coordinator {
        private var source: String?
        private var work: Task<Void, Never>?
        private var owner = UUID()
        func cancel() { owner = UUID(); work?.cancel(); work = nil }
        func load(_ value: String, in text: NSTextView, loading: Binding<Bool>) {
            guard source != value else { return }
            cancel(); source = value; let current = owner
            work = Task { [weak self, weak text] in
                guard let self, let text else { return }
                loading.wrappedValue = true
                text.textStorage?.setAttributedString(.init(string: ""))
                let source = value as NSString; var offset = 0
                while offset < source.length {
                    guard !Task.isCancelled, self.owner == current else { return }
                    var count = min(32_768, source.length - offset)
                    // Preserve UTF-16 surrogate pairs at batch boundaries.
                    if offset + count < source.length, (0xD800...0xDBFF).contains(source.character(at: offset + count - 1)) { count += 1 }
                    let chunk = source.substring(with: NSRange(location: offset, length: count))
                    text.textStorage?.beginEditing()
                    text.textStorage?.append(.init(string: chunk, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
                    text.textStorage?.endEditing()
                    offset += count
                    do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
                }
                guard self.owner == current else { return }
                loading.wrappedValue = false
            }
        }
    }
}
extension RunSummary: @retroactive Identifiable {}
