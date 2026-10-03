import AppKit
import SwiftUI

@main
struct KabanSpikesApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            SpikePickerView()
        }
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra("Kaban Spikes", systemImage: "square.grid.3x3") {
            MenuBarPanel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            SpikeNotifier.shared.install()
            SpikeAgentClient.shared.startStatusPoll()
            SpikeFileLog.append("app", "launch \(SpikeAgentClient.shared.bundlePath)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            SpikeAgentClient.shared.refreshStatus()
        }
    }
}

struct MenuBarPanel: View {
    @State private var client = SpikeAgentClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kaban Spikes")
                .font(.headline)
            Text("Окно можно закрыть: процесс жив, пока вы не нажмёте «Завершить».")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("XPC: \(client.phase)")
                .font(.caption.monospaced())
            Button("Уведомление с ответом") {
                SpikeNotifier.shared.postQuestion()
            }
            Button("Инцидент timeSensitive") {
                SpikeNotifier.shared.postIncident()
            }
            Button("Открыть окно") {
                NSApp.activate()
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Divider()
            Button("Завершить") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

enum SpikeID: String, CaseIterable, Identifiable {
    case fs1, fs2, fs3, fs4, fs5, fs6, fs7, fs8, fs9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fs1: "FS-1 XPC и демон"
        case .fs2: "FS-2 Дорожки"
        case .fs3: "FS-3 Drag"
        case .fs4: "FS-4 Живой лог"
        case .fs5: "FS-5 Маскоты"
        case .fs6: "FS-6 Уведомления"
        case .fs7: "FS-7 Объекты входа"
        case .fs8: "FS-8 pipeline.yaml"
        case .fs9: "FS-9 Открыть в Cursor"
        }
    }

    var subtitle: String {
        switch self {
        case .fs1: "SMAppService, subscribe, resync"
        case .fs2: "10 × 7 × 50, glass, pinned"
        case .fs3: "Transferable, зоны, ворота"
        case .fs4: "100k событий, TextKit 2"
        case .fs5: "symbolEffect и эмодзи"
        case .fs6: "ответ текстом, timeSensitive"
        case .fs7: "одобрение после переноса"
        case .fs8: "комментарии и порядок"
        case .fs9: "CLI и bundle id"
        }
    }
}

struct SpikePickerView: View {
    @State private var selection: SpikeID? = .fs1

    var body: some View {
        NavigationSplitView {
            List(SpikeID.allCases, selection: $selection) { spike in
                VStack(alignment: .leading, spacing: 2) {
                    Text(spike.title)
                    Text(spike.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(spike)
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch selection ?? .fs1 {
            case .fs1: FS1ConnectionView()
            case .fs2: FS2LanesView()
            case .fs3: FS3DragView()
            case .fs4: FS4LogView()
            case .fs5: FS5MascotView()
            case .fs6: FS6NotificationsView()
            case .fs7: FS7LoginItemsView()
            case .fs8: FS8YamlView()
            case .fs9: FS9CursorView()
            }
        }
        .onAppear {
            SpikeAgentClient.shared.startStatusPoll()
        }
    }
}
