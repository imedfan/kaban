import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LogConsole {
    fileprivate var coordinator: LogTextCoordinator?
    private(set) var usesTextKit2: Bool?
    private(set) var lineCount = 0
    private(set) var appendedEvents = 0
    private(set) var renderedFrom = 0
    private(set) var lastBatchMS: Double = 0
    var followTail = true

    func bind(_ coordinator: LogTextCoordinator) {
        self.coordinator = coordinator
        let engine = coordinator.usesTextKit2
        Task { @MainActor in
            self.usesTextKit2 = engine
        }
    }

    func append(from start: Int, count: Int) {
        guard let coordinator else { return }
        let started = Date()
        let chunk = SpikeSignpost.measure("FS4.Batch") {
            coordinator.append(FS4Events.text(from: start, count: count), lineCount: count)
        }
        _ = chunk
        lastBatchMS = Date().timeIntervalSince(started) * 1000
        appendedEvents += count
        lineCount = coordinator.lineCount
        renderedFrom = coordinator.renderedFrom
    }

    func loadEarlier(chunk: Int) {
        guard let coordinator, renderedFrom > 0 else { return }
        let count = min(chunk, renderedFrom)
        let start = renderedFrom - count
        SpikeSignpost.measure("FS4.LoadEarlier") {
            coordinator.prepend(FS4Events.text(from: start, count: count), lineCount: count, newFrom: start)
        }
        lineCount = coordinator.lineCount
        renderedFrom = coordinator.renderedFrom
    }
}

enum FS4Events {
    static let total = 100_000
    static let maxLines = 50_000
    private static let kinds = ["message", "tool_call", "tool_result", "error", "usage"]

    static func text(from start: Int, count: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for seq in start..<(start + count) {
            let kind = kinds[seq % kinds.count]
            let color: NSColor
            switch kind {
            case "error": color = .systemRed
            case "tool_call": color = .systemBlue
            case "usage": color = .systemGreen
            default: color = .labelColor
            }
            let padded = kind.padding(toLength: 11, withPad: " ", startingAt: 0)
            let line = String(format: "%06d", seq) + " \(padded) run=\(seq % 17) path=Sources/File\(seq % 200).swift\n"
            result.append(NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: color,
            ]))
        }
        return result
    }
}

struct FS4LogView: View {
    @State private var console = LogConsole()
    @State private var intervalMS = 150.0
    @State private var streaming = false
    @State private var nextSeq = 0

    var body: some View {
        SpikeScreen(
            code: "FS-4",
            title: "LogTextView, 100 тысяч событий",
            instruments: "Instruments: Allocations (persistent bytes NSTextStorage), Time Profiler, Points of Interest FS4.Batch и FS4.LoadEarlier."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(engineLabel)
                    Text("события \(console.appendedEvents)/\(FS4Events.total)")
                    Text("строк в поле \(console.lineCount)")
                    Text("с seq \(console.renderedFrom)")
                    Text(String(format: "батч %.1f мс", console.lastBatchMS))
                    Spacer()
                }
                .font(.caption.monospaced())
                HStack {
                    Slider(value: $intervalMS, in: 100...250, step: 10) {
                        Text("интервал")
                    }
                    Text("\(Int(intervalMS)) мс")
                        .font(.caption.monospacedDigit())
                        .frame(width: 56)
                    Toggle("следить за концом", isOn: Bindable(console).followTail)
                    Button(streaming ? "Стрим…" : "Пустить 100k") { streaming = true }
                        .disabled(streaming || nextSeq >= FS4Events.total)
                    Button("Загрузить ранее") { console.loadEarlier(chunk: 2000) }
                        .disabled(console.renderedFrom == 0)
                }
                LogTextRepresentable(console: console)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("В поле не больше \(FS4Events.maxLines) строк. ⌘F — панель поиска. Автопрокрутка только у нижнего края.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .task(id: streaming) {
                guard streaming else { return }
                let batch = 400
                while nextSeq < FS4Events.total && !Task.isCancelled {
                    let started = Date()
                    let count = min(batch, FS4Events.total - nextSeq)
                    console.append(from: nextSeq, count: count)
                    nextSeq += count
                    let spent = Date().timeIntervalSince(started)
                    let pause = max(0, intervalMS / 1000 - spent)
                    if pause > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                    }
                }
                streaming = false
                SpikeFileLog.append(
                    "fs4",
                    "done events=\(console.appendedEvents) lines=\(console.lineCount) from=\(console.renderedFrom) tk2=\(String(describing: console.usesTextKit2))"
                )
            }
        }
    }

    private var engineLabel: String {
        switch console.usesTextKit2 {
        case true: "TextKit 2"
        case false: "не TextKit 2"
        case nil: "движок…"
        }
    }
}

struct LogTextRepresentable: NSViewRepresentable {
    var console: LogConsole

    func makeCoordinator() -> LogTextCoordinator {
        let coordinator = LogTextCoordinator()
        coordinator.followTail = { console.followTail }
        coordinator.onFollowChange = { console.followTail = $0 }
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true

        context.coordinator.attach(textView: textView, scroll: scroll)
        console.bind(context.coordinator)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

@MainActor
final class LogTextCoordinator: NSObject {
    private var textView: NSTextView?
    private var scroll: NSScrollView?
    private var observer: NSObjectProtocol?
    private var programmatic = false
    var followTail: () -> Bool = { true }
    var onFollowChange: (Bool) -> Void = { _ in }
    private(set) var lineCount = 0
    var renderedFrom = 0
    var usesTextKit2: Bool { textView?.textLayoutManager != nil }

    func attach(textView: NSTextView, scroll: NSScrollView) {
        self.textView = textView
        self.scroll = scroll
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.userScrolled()
            }
        }
    }

    func append(_ text: NSAttributedString, lineCount added: Int) {
        guard let storage = textView?.textStorage else { return }
        let stick = followTail() && isNearBottom()
        programmatic = true
        storage.beginEditing()
        storage.append(text)
        lineCount += added
        trimIfNeeded(storage)
        storage.endEditing()
        if stick {
            textView?.scrollToEndOfDocument(nil)
        }
        programmatic = false
    }

    func prepend(_ text: NSAttributedString, lineCount added: Int, newFrom: Int) {
        guard let storage = textView?.textStorage else { return }
        programmatic = true
        storage.beginEditing()
        storage.insert(text, at: 0)
        lineCount += added
        renderedFrom = newFrom
        trimFromEndIfNeeded(storage)
        storage.endEditing()
        programmatic = false
    }

    private func trimIfNeeded(_ storage: NSTextStorage) {
        guard lineCount > FS4Events.maxLines else { return }
        let extra = lineCount - FS4Events.maxLines
        let ns = storage.string as NSString
        var index = 0
        var found = 0
        while found < extra && index < ns.length {
            let range = ns.range(of: "\n", range: NSRange(location: index, length: ns.length - index))
            if range.location == NSNotFound { break }
            index = range.location + range.length
            found += 1
        }
        if index > 0 {
            storage.deleteCharacters(in: NSRange(location: 0, length: index))
            lineCount -= found
            renderedFrom += found
        }
    }

    /// После «Загрузить ранее» оставляем начало (только что добавленные старые строки) и срезаем хвост.
    private func trimFromEndIfNeeded(_ storage: NSTextStorage) {
        guard lineCount > FS4Events.maxLines else { return }
        let ns = storage.string as NSString
        var found = 0
        var index = 0
        while found < FS4Events.maxLines && index < ns.length {
            let range = ns.range(of: "\n", range: NSRange(location: index, length: ns.length - index))
            if range.location == NSNotFound { return }
            index = range.location + range.length
            found += 1
        }
        if index < ns.length {
            storage.deleteCharacters(in: NSRange(location: index, length: ns.length - index))
            lineCount = found
        }
    }

    private func isNearBottom() -> Bool {
        guard let scroll, let textView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= textView.bounds.maxY - 48
    }

    private func userScrolled() {
        guard !programmatic, followTail(), !isNearBottom() else { return }
        onFollowChange(false)
    }
}
