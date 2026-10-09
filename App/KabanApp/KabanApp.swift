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
        .commands { ReviewQAWindowCommands() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая задача") { runtime.store?.beginCreation() }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Найти") { runtime.store?.find() }.keyboardShortcut("f")
                Button("Закрыть детали") { Task { await runtime.store?.select(nil) } }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Задача") {
                Button("Ответить или одобрить результат") {
                    if !runtime.showSetup, let store = runtime.store {
                        if let route = store.suspiciousReturnRoute { Task { await store.suspiciousFiles.submitReturn(route.taskID) } }
                        else if let preview = store.gitPermissions.preview { Task { await preview.save() } }
                        else if let editor = store.activePipelineEditor { Task { await editor.apply() } }
                        else if let settings = store.activeProjectSettings { Task { await settings.submit() } }
                        else if let settings = store.activeMacSettings, let section = settings.section { Task { await settings.submit(section) } }
                        else if store.canResolveIncident { store.resolveIncident() }
                        else if store.canApproveSelected { store.approveSelected() } else { store.answerSelected() }
                    }
                }.keyboardShortcut(.return, modifiers: [.command])
                Divider()
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
        MenuBarExtra {
            MenuBarView(runtime: runtime).preferredColorScheme(qaTheme)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: runtime.store?.projection?.ephemeral.schedulerFlags.isEmpty == false ? "exclamationmark.triangle" : "list.bullet.rectangle")
                Text(runtime.store?.projection == nil ? "—" : "\(runtime.store?.waitingCount ?? 0)")
            }
                .accessibilityLabel(runtime.store?.projection == nil ? "Kaban. Нет данных о задачах" : "Kaban. Ждут человека: \(runtime.store?.waitingCount ?? 0)")
        }.menuBarExtraStyle(.window)
    }
}

/// Explicitly presents the actual WindowGroup when LaunchServices suppresses
/// the automatic window during isolated live acceptance. Absent in normal use.
private struct ReviewQAWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            if BoardQA.needsExplicitWindow {
                Button("Открыть окно ревью для проверки") { openWindow(id: "board") }
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
                if item.keyEquivalent == "\r", item.keyEquivalentModifierMask == .command {
                    item.target = self; item.action = #selector(primaryTask(_:))
                }
                if let action = TaskMenuAction.allCases.first(where: { $0.title == item.title }) {
                    item.tag = action.rawValue; item.target = self; item.action = #selector(controlTask(_:))
                }
                bindControls(item.submenu)
            }
        }
        bindControls(NSApp.mainMenu)
    }
    @objc private func createTask(_ sender: NSMenuItem) { runtime?.store?.beginCreation() }
    @objc private func primaryTask(_ sender: NSMenuItem) {
        guard runtime?.showSetup == false, let store = runtime?.store else { return }
        if let route = store.suspiciousReturnRoute { Task { await store.suspiciousFiles.submitReturn(route.taskID) } }
        else if let preview = store.gitPermissions.preview { Task { await preview.save() } }
        else if let editor = store.activePipelineEditor { Task { await editor.apply() } }
        else if let settings = store.activeProjectSettings { Task { await settings.submit() } }
        else if let settings = store.activeMacSettings, let section = settings.section { Task { await settings.submit(section) } }
        else if store.canResolveIncident { store.resolveIncident() }
        else if store.canApproveSelected { store.approveSelected() } else { store.answerSelected() }
    }
    @objc private func controlTask(_ sender: NSMenuItem) {
        if let action = TaskMenuAction(rawValue: sender.tag) { runtime?.store?.perform(action) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(primaryTask(_:)) {
            if let route = runtime?.store?.suspiciousReturnRoute {
                menuItem.title = "Вернуть задачу с решением по файлам"
                return runtime?.showSetup == false && runtime?.store?.suspiciousFiles.canReturn(route.taskID) == true
            }
            if let preview = runtime?.store?.gitPermissions.preview {
                menuItem.title = "Сохранить правило git"
                return runtime?.showSetup == false && preview.canSave
            }
            if let settings = runtime?.store?.activeMacSettings {
                menuItem.title = settings.section == .ceiling ? "Сохранить потолок" : "Применить квоту"
                return runtime?.showSetup == false && settings.section.map(settings.canSubmit) == true
            }
            if let editor = runtime?.store?.activePipelineEditor {
                menuItem.title = "Применить пайплайн"
                return runtime?.showSetup == false && editor.canApply
            }
            if let settings = runtime?.store?.activeProjectSettings {
                menuItem.title = "Сохранить настройки проекта"
                return runtime?.showSetup == false && settings.canSubmit
            }
            let approve = runtime?.store?.canApproveSelected == true
            menuItem.title = runtime?.store?.canResolveIncident == true ? "Вернуть с замечанием по инциденту" : approve ? "Одобрить результат ревью" : "Отправить ответ агенту"
            return runtime?.showSetup == false && (approve || runtime?.store?.canAnswerSelected == true || runtime?.store?.canResolveIncident == true)
        }
        if menuItem.action == #selector(createTask(_:)) { return runtime?.store?.can(.createTask) == true && runtime?.store?.controlSheet == nil && runtime?.store?.projectSheet == nil && runtime?.store?.reviewRoute == nil && runtime?.store?.overlapRoute == nil && runtime?.store?.suspiciousReturnRoute == nil && runtime?.store?.gitPermissions.preview == nil }
        if menuItem.action == #selector(controlTask(_:)), let action = TaskMenuAction(rawValue: menuItem.tag) { return runtime?.store?.canPerform(action) == true }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stopForTermination()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Kaban", withExtension: "icns", subdirectory: "Resources"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        if BoardQA.isActive { NSApp.setActivationPolicy(.regular); NSApp.activate(); Task { await BoardQA.run() } }
    }
}
