import Observation
import SwiftUI

enum MascotMode: String, CaseIterable, Identifiable {
    case sleep
    case work
    case wait
    case done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sleep: "спит · breathe"
        case .work: "работает · pulse"
        case .wait: "ждёт · wiggle"
        case .done: "Done · bounce"
        }
    }
}

private struct WiggleValue {
    var degrees: Double = 0
}

struct FS5MascotView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 10
    @State private var mode: MascotMode = .work
    @State private var bounceTick = 0
    @State private var includeEmoji = true
    @State private var report = ""

    private let symbols = ["hare.fill", "tortoise.fill", "bird.fill", "fish.fill", "lizard.fill", "ant.fill"]
    private let emojis = ["🦊", "🐙", "🦉", "🐝", "🐢", "🐧"]

    var body: some View {
        SpikeScreen(
            code: "FS-5",
            title: "symbolEffect и keyframeAnimator",
            instruments: "Instruments: Energy Log и Time Profiler в простое. Встроенный замер — CPU процесса за 20 с, мышь не двигать."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper("N = \(count)", value: $count, in: 1...40)
                    Picker("режим", selection: $mode) {
                        ForEach(MascotMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("эмодзи", isOn: $includeEmoji)
                    Button("Done") { bounceTick += 1 }
                    Button("Замер 20 с") { Task { await measureIdle() } }
                }
                Text(reduceMotion ? "Reduce Motion включён: анимация должна быть статичной." : "Reduce Motion выключен.")
                    .font(.caption)
                Text(report)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                        ForEach(0..<count, id: \.self) { index in
                            VStack(spacing: 6) {
                                Image(systemName: symbols[index % symbols.count])
                                    .font(.system(size: 28))
                                    .symbolEffect(.breathe, isActive: mode == .sleep && !reduceMotion)
                                    .symbolEffect(.pulse, isActive: mode == .work && !reduceMotion)
                                    .symbolEffect(.wiggle, options: .repeating, isActive: mode == .wait && !reduceMotion)
                                    .symbolEffect(.bounce, value: bounceTick)
                                if includeEmoji {
                                    emoji(emojis[index % emojis.count])
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(8)
                        }
                    }
                    .padding(12)
                }
                Text("НЕ ПРОВЕРЕНО: `.symbolEffect(.wiggle, options: .repeating, isActive:)`. Если не соберётся, замените на `.symbolEffect(.wiggle, options: .repeat(.continuous), value: mode)`.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func emoji(_ text: String) -> some View {
        if reduceMotion {
            Text(text).font(.system(size: 28))
        } else {
            Text(text)
                .font(.system(size: 28))
                .keyframeAnimator(initialValue: WiggleValue(), repeating: mode == .wait) { content, value in
                    content.rotationEffect(.degrees(value.degrees))
                } keyframes: { _ in
                    KeyframeTrack(\.degrees) {
                        CubicKeyframe(0, duration: 0.15)
                        CubicKeyframe(14, duration: 0.2)
                        CubicKeyframe(-14, duration: 0.3)
                        CubicKeyframe(0, duration: 0.2)
                    }
                }
        }
    }

    private func measureIdle() async {
        report = "замер…"
        SpikeSignpost.event("FS5.IdleSample")
        var lastCPU = ProcessStats.cpuSeconds()
        var lastWall = Date()
        var samples: [Double] = []
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let cpu = ProcessStats.cpuSeconds()
            let wall = Date()
            let delta = wall.timeIntervalSince(lastWall)
            if delta > 0 {
                samples.append((cpu - lastCPU) / delta * 100)
            }
            lastCPU = cpu
            lastWall = wall
        }
        let average = samples.reduce(0, +) / Double(max(samples.count, 1))
        let maxSample = samples.max() ?? 0
        report = "N=\(count) эмодзи=\(includeEmoji ? "да" : "нет") режим=\(mode.rawValue) среднее \(String(format: "%.1f", average))% макс \(String(format: "%.1f", maxSample))% (20 с)"
        SpikeFileLog.append("fs5", report)
    }
}
