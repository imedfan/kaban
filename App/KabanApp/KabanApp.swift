import SwiftUI
import KabanBoardCore

@main struct KabanApp: App {
    @NSApplicationDelegateAdaptor(KabanAppDelegate.self) private var delegate
    @State private var runtime = DaemonRuntime()
    private var qaTheme: ColorScheme? { BoardQA.argument("--qa-theme").map { $0 == "dark" ? .dark : .light } }
    var body: some Scene {
        WindowGroup("Kaban", id: "board") {
            DaemonRuntimeView(runtime: runtime)
                .onAppear { delegate.bindTaskCommand(to: runtime) }
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

@MainActor final class KabanAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private weak var runtime: DaemonRuntime?
    /// Native validation queries the live session at menu/shortcut time, rather than
    /// retaining the disabled value from SwiftUI's initial disconnected command tree.
    func bindTaskCommand(to runtime: DaemonRuntime) {
        self.runtime = runtime
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == "Новая задача", item.keyEquivalent == "n" { return item }
                if let nested = find(item.submenu) { return nested }
            }
            return nil
        }
        guard let item = find(NSApp.mainMenu) else { return }
        item.target = self; item.action = #selector(createTask(_:))
        item.menu?.update()
    }
    @objc private func createTask(_ sender: NSMenuItem) { runtime?.store?.beginCreation() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(createTask(_:)) { return runtime?.store?.can(.createTask) == true }
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Kaban", withExtension: "icns", subdirectory: "Resources"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        if BoardQA.isActive { NSApp.setActivationPolicy(.regular); NSApp.activate(); Task { await BoardQA.run() } }
    }
}
