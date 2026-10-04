import SwiftUI

struct SpikeScreen<Content: View>: View {
    let code: String
    let title: String
    let instruments: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(code) · \(title)")
                    .font(.title2.bold())
                Text(instruments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            MetricsBar()
        }
    }
}

struct MetricsBar: View {
    @State private var footprint = "—"
    @State private var cpu = "—"
    @State private var lastCPU: TimeInterval?
    @State private var lastDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                Text(context.date, format: .dateTime.hour().minute().second())
                Text("phys_footprint \(footprint) МБ")
                Text("CPU процесса \(cpu)%")
                Spacer()
                Text(SpikeFileLog.sessionURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .onChange(of: context.date) { _, date in
                let snap = ProcessStats.snapshot()
                if let bytes = snap.footprintBytes {
                    footprint = String(format: "%.1f", Double(bytes) / 1_048_576)
                } else {
                    footprint = "n/a"
                }
                if let lastCPU, let lastDate {
                    let delta = date.timeIntervalSince(lastDate)
                    if delta > 0 {
                        cpu = String(format: "%.1f", (snap.cpuSeconds - lastCPU) / delta * 100)
                    }
                }
                lastCPU = snap.cpuSeconds
                lastDate = date
            }
        }
    }
}

struct LogList: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .background(.quaternary.opacity(0.35))
            .onChange(of: lines.count) { _, _ in
                if let last = lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
