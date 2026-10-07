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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(route.title).font(.headline); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
            MaterialTextView(text: route.text)
            Text("\(route.text.utf8.count) байт · исходный текст целиком").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 640, height: 440)
    }
}
struct MaterialTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.usesFindBar = true
        view.isRichText = false; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = .init(width: 10, height: 10)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view; view.string = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
    }
}
extension RunSummary: @retroactive Identifiable {}
/// Bounded separate log reads for inspector fallback. Live tail/navigation is FE-09.
struct TaskLogPageSheet: View {
    let store: BoardStore
    let run: RunSummary
    @Environment(\.dismiss) private var dismiss
    @State private var page: LogPage?
    @State private var failure: String?
    @State private var busy = false
    @State private var offset: Int64 = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Лог · попытка \(run.number)").font(.headline); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(run.id.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if busy { ProgressView("Читаем страницу…") }
            if let failure { Text(failure).font(.system(size: 12)).textSelection(.enabled); Button("Повторить") { Task { await read(offset) } }.disabled(busy) }
            if let page {
                if page.batch.events.isEmpty { Text(page.isComplete ? "В этой странице нет записей" : "Записей пока нет").foregroundStyle(.secondary) }
                MaterialTextView(text: page.batch.events.map { event in
                    // Codable output preserves every field without assuming Cursor's raw format.
                    (try? KabanCoding.makeEncoder().encode(event)).flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: event)
                }.joined(separator: "\n\n"))
                HStack {
                    Text("Записи \(page.batch.fromOffset)…\(page.batch.nextOffset) · доступно с \(page.availableFromOffset)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(page.batch.nextOffset < page.endOffset ? "Следующая страница" : "Обновить") { Task { await read(page.batch.nextOffset) } }.disabled(busy)
                }
            } else { Spacer() }
        }.padding(20).frame(width: 680, height: 440).task { await read(0) }
    }
    private func read(_ from: Int64) async {
        guard !busy else { return }; busy = true; failure = nil; offset = from
        defer { busy = false }
        do {
            let value = try await store.readLog(runId: run.id, fromOffset: from, limit: 100)
            guard value.batch.runId == run.id else { throw CommandError(code: "invalid_reply", message: "Служба вернула лог другого запуска.") }
            page = value
        } catch { failure = error.localizedDescription }
    }
}
