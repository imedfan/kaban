import SwiftUI
import KabanBoardCore

@main struct KabanApp: App {
    @NSApplicationDelegateAdaptor(KabanAppDelegate.self) private var delegate
    @State private var runtime = DaemonRuntime()
    private var qaTheme: ColorScheme? { BoardQA.argument("--qa-theme").map { $0 == "dark" ? .dark : .light } }
    var body: some Scene {
        WindowGroup("Kaban", id: "board") {
            DaemonRuntimeView(runtime: runtime)
                .frame(minWidth: 1040, minHeight: 608)
                .preferredColorScheme(qaTheme)
        }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая задача") { runtime.store?.beginCreation() }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Поиск задач") { runtime.store?.screen = .board; if let store = runtime.store { store.searchRequest += 1 } }.keyboardShortcut("f")
                Button("Закрыть детали") { Task { await runtime.store?.select(nil) } }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Служба Kaban") {
                Button("Проверить состояние") { Task { await runtime.refresh() } }
                Button("Перезапустить службу") { Task { await runtime.restart() } }.disabled(runtime.developer || runtime.fixture)
                Button("Отключить службу") { Task { await runtime.unregister() } }.disabled(runtime.developer || runtime.fixture)
                Button("Открыть объекты входа") { runtime.openSettings() }
            }
            CommandMenu("Доска") {
                ForEach(BoardFilter.allCases, id: \.self) { filter in Button(filter.rawValue) { runtime.store?.screen = .board; runtime.store?.filter = filter } }
            }
        }
    }
}

@MainActor final class KabanAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Kaban", withExtension: "icns", subdirectory: "Resources"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        if BoardQA.isActive { NSApp.setActivationPolicy(.regular); NSApp.activate(); Task { await BoardQA.run() } }
    }
}
