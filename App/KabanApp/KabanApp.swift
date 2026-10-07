import SwiftUI
import KabanBoardCore
import KabanProtocol

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
            CommandMenu("Задача") {
                Button(TaskMenuAction.pauseOrResume.title) { runtime.store?.perform(.pauseOrResume) }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button(TaskMenuAction.move.title) { runtime.store?.perform(.move) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button(TaskMenuAction.retry.title) { runtime.store?.perform(.retry) }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button(TaskMenuAction.cancel.title) { runtime.store?.perform(.cancel) }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            CommandMenu("Служба Kaban") {
                Button("Настройка Kaban…") { runtime.showSetup = true }
                Button("Проверить состояние") { Task { await runtime.refresh() } }
                Button("Перезапустить службу") { Task { await runtime.restart() } }.disabled(runtime.developer || runtime.fixture)
                Button("Отключить службу") { Task { await runtime.unregister() } }.disabled(runtime.developer || runtime.fixture)
                Button("Открыть объекты входа") { runtime.openSettings() }
            }
            CommandMenu("Доска") {
                ForEach(BoardFilter.allCases, id: \.self) { filter in Button(filter.rawValue) { runtime.store?.screen = .board; runtime.store?.filter = filter } }
                Divider()
                ForEach(1...9, id: \.self) { index in
                    Button("Проект \(index)") { runtime.store?.focusProject(at: index - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
                }
                Divider()
                Button("Дорожка выше") { if let store = runtime.store, let id = store.selectedProjectID { store.moveProject(id, by: -1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Дорожка ниже") { if let store = runtime.store, let id = store.selectedProjectID { store.moveProject(id, by: 1) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Предыдущая дорожка") { if let store = runtime.store, let id = store.selectedProjectID { store.moveProject(id, by: -1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Следующая дорожка") { if let store = runtime.store, let id = store.selectedProjectID { store.moveProject(id, by: 1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Скрыть выбранный проект") { if let store = runtime.store, let id = store.selectedProjectID { store.hide(id) } }
                Button("Показать выбранный проект") { if let store = runtime.store, let id = store.selectedProjectID { store.focusProject(id) } }

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
        func bindControls(_ menu: NSMenu?) {
            for item in menu?.items ?? [] {
                if let action = TaskMenuAction.allCases.first(where: { $0.title == item.title }) {
                    item.tag = action.rawValue; item.target = self; item.action = #selector(controlTask(_:))
                }
                bindControls(item.submenu)
            }
        }
        bindControls(NSApp.mainMenu)
    }
    @objc private func createTask(_ sender: NSMenuItem) { runtime?.store?.beginCreation() }
    @objc private func controlTask(_ sender: NSMenuItem) {
        if let action = TaskMenuAction(rawValue: sender.tag) { runtime?.store?.perform(action) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(createTask(_:)) { return runtime?.store?.can(.createTask) == true && runtime?.store?.controlSheet == nil && runtime?.store?.projectSheet == nil }
        if menuItem.action == #selector(controlTask(_:)), let action = TaskMenuAction(rawValue: menuItem.tag) { return runtime?.store?.canPerform(action) == true }
        return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Kaban", withExtension: "icns", subdirectory: "Resources"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        if BoardQA.isActive { NSApp.setActivationPolicy(.regular); NSApp.activate(); Task { await BoardQA.run() } }
    }
}
