import AppKit
import SwiftUI
import KabanProtocol
import KabanBoardCore

/// TextKit 2 reader. Formatting is prepared off the UI actor; native storage
/// receives one edit group per batch, preserving selection and the reading anchor.
struct RunLogTextView: NSViewRepresentable {
    let runID: RunID?
    let entries: [RunLogEntry]
    let mode: RunLogMode
    let dark: Bool
    var searchRequest = 0
    var scrollToLatestRequest = 0
    @Binding var followsLatest: Bool
    let onOpenSource: (Int64) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let text = NSTextView(usingTextLayoutManager: true)
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.isAutomaticLinkDetectionEnabled = false; text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = .init(width: 12, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.attach(scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: RunLogTextView
        private weak var scroll: NSScrollView?
        private var observer: NSObjectProtocol?
        private var work: Task<Void, Never>?
        private var token = UUID()
        private var sourceRun: RunID?
        private var snapshot: [RunLogEntry] = []
        private var prepared: [LogTextRecord] = []
        private var ranges: [(offset: Int64, range: NSRange)] = []
        private var expanded: Set<Int64> = []
        private var applying = false
        private var previousSearch = 0
        private var previousScroll = 0

        init(_ parent: RunLogTextView) { self.parent = parent }
        func attach(_ scroll: NSScrollView) {
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                              object: scroll.contentView, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scrolled() }
            }
        }
        func stop() {
            token = UUID(); work?.cancel(); work = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
            prepared = []; snapshot = []; ranges = []; expanded = []
        }
        func update(_ value: RunLogTextView, force: Bool = false) {
            let changedMode = parent.mode != value.mode
            parent = value
            guard let text = scroll?.documentView as? NSTextView else { return }
            text.appearance = NSAppearance(named: value.dark ? .darkAqua : .aqua)
            if previousSearch != value.searchRequest {
                previousSearch = value.searchRequest
                text.window?.makeFirstResponder(text)
                let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
                text.performTextFinderAction(item)
            }
            let forcedScroll = previousScroll != value.scrollToLatestRequest
            previousScroll = value.scrollToLatestRequest
            if sourceRun != value.runID {
                token = UUID(); work?.cancel(); work = nil
                sourceRun = value.runID; snapshot = []; prepared = []; ranges = []; expanded = []
                text.textStorage?.setAttributedString(.init(string: ""))
            }
            if !force, !changedMode, snapshot == value.entries {
                if forcedScroll { text.scrollToEndOfDocument(nil) }
                return
            }
            snapshot = value.entries
            let retained = Set(value.entries.map(\.offset)); expanded.formIntersection(retained)
            let entries = value.entries, expanded = expanded, cache = Dictionary(uniqueKeysWithValues: prepared.map { ($0.entry.offset, $0) })
            work?.cancel(); let owner = UUID(); token = owner
            work = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) { () throws -> [LogTextRecord] in
                    try entries.map { entry in
                        try Task.checkCancellation()
                        let isExpanded = expanded.contains(entry.offset)
                        if let old = cache[entry.offset], old.entry == entry, old.expanded == isExpanded { return old }
                        return LogTextRecord(entry: entry, expanded: isExpanded)
                    }
                }
                do {
                    let records = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                       onCancel: { worker.cancel() })
                    guard let self, self.token == owner, !Task.isCancelled else { return }
                    self.install(records, forceScroll: forcedScroll)
                } catch is CancellationError {}
                catch { /* Formatter only throws cancellation; source failures belong to RunLogStore. */ }
            }
        }
        private var atBottom: Bool {
            guard let scroll, let text = scroll.documentView else { return true }
            return text.bounds.maxY - scroll.contentView.bounds.maxY <= 24
        }
        private func scrolled() {
            guard !applying else { return }
            let follow = parent.mode == .latest && atBottom
            if parent.followsLatest != follow { parent.followsLatest = follow }
        }
        private func install(_ records: [LogTextRecord], forceScroll: Bool) {
            guard let scroll, let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
            applying = true; defer { applying = false }
            let shouldFollow = parent.mode == .latest && (forceScroll || (parent.followsLatest && atBottom) || prepared.isEmpty)
            let character = text.characterIndexForInsertion(at: .init(x: text.visibleRect.minX + 14, y: text.visibleRect.minY + 3))
            let anchor = ranges.last(where: { $0.range.location <= character })
            let withinAnchor = anchor.map { max(0, character - $0.range.location) } ?? 0
            let screenY = storage.length > 0 ? text.firstRect(forCharacterRange: NSRange(location: min(character, storage.length), length: 0), actualRange: nil).minY : nil
            let selected = text.selectedRanges
            func point(_ index: Int) -> (offset: Int64, within: Int)? {
                guard let item = ranges.last(where: { $0.range.location <= index }) else { return nil }
                return (item.offset, min(index - item.range.location, item.range.length))
            }
            let selections = selected.map { (point($0.rangeValue.location), point(NSMaxRange($0.rangeValue))) }
            let first = records.first?.entry.offset
            let retained = first.flatMap { start in prepared.firstIndex { $0.entry.offset == start } }
            let incremental: Bool
            if let retained {
                let overlap = min(prepared.count - retained, records.count)
                incremental = zip(prepared.dropFirst(retained).prefix(overlap), records.prefix(overlap)).allSatisfy { $0 == $1 }
            } else { incremental = prepared.isEmpty }
            storage.beginEditing()
            if incremental, let retained {
                let prefixLength = retained < ranges.count ? ranges[retained].range.location : 0
                if prefixLength > 0 { storage.deleteCharacters(in: NSRange(location: 0, length: prefixLength)) }
                ranges = ranges.dropFirst(retained).map { ($0.offset, NSRange(location: $0.range.location - prefixLength, length: $0.range.length)) }
                let oldCount = ranges.count
                if records.count < oldCount {
                    let end = records.isEmpty ? 0 : NSMaxRange(ranges[records.count - 1].range)
                    storage.deleteCharacters(in: NSRange(location: end, length: storage.length - end))
                    ranges = Array(ranges.prefix(records.count))
                } else {
                    append(Array(records.dropFirst(oldCount)), to: storage)
                }
            } else {
                storage.setAttributedString(.init(string: "")); ranges = []
                append(records, to: storage)
            }
            storage.endEditing(); prepared = records
            text.layoutSubtreeIfNeeded()
            if shouldFollow {
                text.scrollToEndOfDocument(nil)
                if !parent.followsLatest { parent.followsLatest = true }
            } else if let anchor, let match = ranges.first(where: { $0.offset == anchor.offset }), let screenY {
                let index = match.range.location + min(withinAnchor, max(0, match.range.length - 1))
                let rect = text.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
                let target = scroll.contentView.bounds.minY + rect.minY - screenY
                // Text view coordinates are flipped; screen coordinates grow upwards.
                let adjusted = scroll.contentView.bounds.minY - (rect.minY - screenY)
                _ = target
                let y = max(0, min(adjusted, max(0, text.bounds.height - scroll.contentView.bounds.height)))
                scroll.contentView.scroll(to: .init(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            // Preserve selections by record/character, including prefix eviction.
            // A removed selection must not silently select a different record.
            let restored: [NSValue] = selections.compactMap { start, end in
                guard let start, let end,
                      let first = ranges.first(where: { $0.offset == start.offset }),
                      let last = ranges.first(where: { $0.offset == end.offset }) else { return nil }
                let from = first.range.location + min(start.within, first.range.length)
                let to = last.range.location + min(end.within, last.range.length)
                guard to >= from, to <= storage.length else { return nil }
                return NSValue(range: NSRange(location: from, length: to - from))
            }
            if !restored.isEmpty { text.selectedRanges = restored }
            else if !selected.isEmpty { text.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        private func append(_ records: [LogTextRecord], to storage: NSTextStorage) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            for record in records {
                let begin = storage.length
                let value = NSMutableAttributedString(string: record.text,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                 .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
                value.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                                     .foregroundColor: record.entry.kind == .error ? NSColor.systemRed : NSColor.secondaryLabelColor],
                                    range: NSRange(location: 0, length: record.headingLength))
                if let link = record.link {
                    value.addAttribute(.link, value: "kaban-log-\(link.rawValue):\(record.entry.offset)",
                                       range: NSRange(location: record.linkLocation, length: record.linkLength))
                }
                storage.append(value); ranges.append((record.entry.offset, NSRange(location: begin, length: value.length)))
            }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let value = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let offset = Int64(parts[1]), snapshot.contains(where: { $0.offset == offset }) else { return true }
            if parts[0] == "kaban-log-tool" {
                if expanded.contains(offset) { expanded.remove(offset) } else { expanded.insert(offset) }
                update(parent, force: true)
            } else if parts[0] == "kaban-log-source" { parent.onOpenSource(offset) }
            return true // No arbitrary URL/file navigation from text produced by an agent.
        }
    }
}

private enum LogTextLink: String, Sendable { case tool, source }
private struct LogTextRecord: Equatable, Sendable {
    let entry: RunLogEntry
    let expanded: Bool
    let text: String
    let headingLength: Int
    let link: LogTextLink?
    let linkLocation: Int
    let linkLength: Int

    init(entry: RunLogEntry, expanded: Bool) {
        self.entry = entry; self.expanded = expanded
        let heading: String, body: String
        var destination: LogTextLink?
        if let event = entry.event {
            switch event {
            case .initialized(let model, let session):
                heading = "Инициализация"
                body = "Модель: \(model ?? "не передана")" + (session.map { "\nСессия: " + $0 } ?? "")
            case .message(let role, let text):
                heading = ["assistant": "Агент", "user": "Пользователь", "system": "Система"][role] ?? role
                body = text
            case .toolCall(_, let name, let summary):
                heading = "\(expanded ? "▾" : "▸") Инструмент · \(name)"; destination = .tool
                body = expanded ? summary : Self.preview(summary)
            case .toolResult(let id, let ok, let summary):
                heading = "\(expanded ? "▾" : "▸") Результат · \(id) · \(ok ? "успех" : "ошибка")"; destination = .tool
                body = expanded ? summary : Self.preview(summary)
            case .usage(let input, let output):
                heading = "Токены · вход \(input.map(String.init) ?? "неизвестно") · выход \(output.map(String.init) ?? "неизвестно")"
                body = ""
            case .error(let code, let message):
                heading = "Ошибка" + (code.map { " · " + $0 } ?? ""); body = message
            case .result(let ok, let duration):
                heading = ok ? "Результат · успех" : "Результат · ошибка"
                body = duration.map { "Длительность из лога: \($0) мс" } ?? "Длительность не передана"
            }
        } else {
            heading = "Крупная запись · \(entry.sourceBytes) байт · \(entry.sourceLines) строк"
            body = "Открыть запись целиком"; destination = .source
        }
        text = heading + (body.isEmpty ? "" : "\n" + body) + "\n\n"
        headingLength = heading.utf16.count
        link = destination
        linkLocation = destination == .source ? headingLength + 1 : 0
        linkLength = destination == .source ? body.utf16.count : headingLength
    }
    private static func preview(_ text: String) -> String {
        let first = text.firstIndex(of: "\n").map { String(text[..<$0]) } ?? text
        let brief = String(first.prefix(160))
        return brief + (brief.count < text.count ? " …" : "")
    }
}
