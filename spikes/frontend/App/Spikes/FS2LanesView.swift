import AppKit
import Observation
import SwiftUI

enum FS2Scale {
    static let lanes = 10
    static let columns = 7
    static let cardsPerColumn = 50
}

struct FS2Lane: Identifiable {
    var id: Int
    var name: String
    var emoji: String
    var columns: [FS2Column]
}

struct FS2Column: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var cards: [FS2Card]
}

struct FS2Card: Identifiable, Equatable {
    var id: String
    var title: String
    var status: String
    var symbol: String
}

@MainActor
@Observable
final class AppearCounter {
    private(set) var count = 0
    private var seen: Set<String> = []

    func mark(_ id: String) {
        if seen.insert(id).inserted {
            count += 1
        }
    }

    func reset() {
        seen.removeAll()
        count = 0
    }
}

@MainActor
final class FPSCounter {
    private var last = Date()
    private var frames = 0
    private(set) var fps = 0

    func tick() -> Int {
        frames += 1
        let now = Date()
        let delta = now.timeIntervalSince(last)
        if delta >= 0.5 {
            fps = Int((Double(frames) / delta).rounded())
            frames = 0
            last = now
        }
        return fps
    }
}

struct FS2LanesView: View {
    @State private var lanes: [FS2Lane] = []
    @State private var appeared = AppearCounter()
    @State private var fpsCounter = FPSCounter()
    @State private var generateMS: Double = 0

    private var expected: Int { FS2Scale.lanes * FS2Scale.columns * FS2Scale.cardsPerColumn }

    var body: some View {
        SpikeScreen(
            code: "FS-2",
            title: "Дорожки, вложенный скролл, glass",
            instruments: "Instruments: Animation Hitches, Time Profiler, Points of Interest (FS2.Generate, FS2.BoardAppear). Счётчик fps — в углу доски."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(FS2Scale.lanes) × \(FS2Scale.columns) × \(FS2Scale.cardsPerColumn) = \(lanes.isEmpty ? 0 : expected)")
                    Text(String(format: "генерация %.1f мс", generateMS))
                    Text("материализовано \(appeared.count)")
                    Button("Сбросить счётчик") { appeared.reset() }
                    Spacer()
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 16)
                if lanes.isEmpty {
                    ProgressView("Собираю доску")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    board
                }
            }
        }
        .task {
            guard lanes.isEmpty else { return }
            let started = Date()
            let built = SpikeSignpost.measure("FS2.Generate") { FS2Fixture.make() }
            generateMS = Date().timeIntervalSince(started) * 1000
            lanes = built
            SpikeFileLog.append("fs2", String(format: "generated %d cards in %.1f ms", expected, generateMS))
        }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: .sectionHeaders) {
                ForEach(lanes) { lane in
                    Section {
                        laneBody(lane)
                    } header: {
                        laneHeader(lane)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: NSColor.windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            TimelineView(.animation) { _ in
                Text("\(fpsCounter.tick()) fps")
                    .font(.caption.monospacedDigit().bold())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .onAppear {
            SpikeSignpost.event("FS2.BoardAppear")
        }
    }

    private func laneHeader(_ lane: FS2Lane) -> some View {
        HStack(spacing: 8) {
            Text(lane.emoji)
            Text(lane.name).font(.headline)
            Text("main")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(FS2Scale.columns * FS2Scale.cardsPerColumn) карточек")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
    }

    private func laneBody(_ lane: FS2Lane) -> some View {
        GlassEffectContainer(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(lane.columns) { column in
                        columnView(column)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(height: 460)
    }

    private func columnView(_ column: FS2Column) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: column.symbol)
                Text(column.title)
                    .lineLimit(1)
                Spacer()
                Text("\(column.cards.count)")
                    .font(.caption.monospacedDigit())
            }
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(column.cards) { card in
                        cardView(card)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 210)
        .background(Color(nsColor: NSColor.underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func cardView(_ card: FS2Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: card.symbol)
                Text(card.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { appeared.mark(card.id) }
    }
}

enum FS2Fixture {
    static let columnTitles = ["Backlog", "Dev", "Test", "AI Review", "Human Review", "Merge", "Done"]
    static let columnSymbols = [
        "tray", "hammer", "testtube.2", "sparkle", "person", "arrow.triangle.merge", "checkmark",
    ]
    static let statuses = [
        ("В очереди", "clock"),
        ("Работает", "bolt"),
        ("Ждёт человека", "person.crop.circle.badge.questionmark"),
        ("Готово", "checkmark.circle"),
    ]

    static func make() -> [FS2Lane] {
        let emojis = ["🦊", "🐙", "🦉", "🐝", "🐢", "🐧", "🐸", "🦁", "🦄", "🐼"]
        return (0..<FS2Scale.lanes).map { lane in
            let columns: [FS2Column] = (0..<FS2Scale.columns).map { column in
                let cards: [FS2Card] = (0..<FS2Scale.cardsPerColumn).map { index in
                    let status = statuses[(lane + column + index) % statuses.count]
                    return FS2Card(
                        id: "\(lane)-\(column)-\(index)",
                        title: "SHOP-\(lane * 1000 + column * 100 + index) задача",
                        status: status.0,
                        symbol: status.1
                    )
                }
                return FS2Column(
                    id: "\(lane)-\(column)",
                    title: columnTitles[column],
                    symbol: columnSymbols[column],
                    cards: cards
                )
            }
            return FS2Lane(id: lane, name: "Проект \(lane + 1)", emoji: emojis[lane], columns: columns)
        }
    }
}
