import SwiftUI
import KabanBoardCore

@main struct KabanApp: App {
    @NSApplicationDelegateAdaptor(KabanAppDelegate.self) private var delegate
    @State private var store = BoardStore(client: AppFixture.client(), storage: BoardQA.isActive ? MemoryKeyValueStore() : DefaultsStorage())
    private var qaTheme: ColorScheme? { BoardQA.argument("--qa-theme").map { $0 == "dark" ? .dark : .light } }
    var body: some Scene {
        WindowGroup("Kaban", id: "board") {
            BoardView(store: store)
                .frame(minWidth: 1040, minHeight: 608)
                .preferredColorScheme(qaTheme)
                .onAppear { BoardQA.store = store }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая задача") { store.beginCreation() }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Поиск задач") { store.screen = .board; store.searchRequest += 1 }.keyboardShortcut("f")
                Button("Закрыть детали") { Task { await store.select(nil) } }.keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Доска") {
                ForEach(BoardFilter.allCases, id: \.self) { filter in Button(filter.rawValue) { store.screen = .board; store.filter = filter } }
            }
        }
    }
}

@MainActor final class KabanAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "Kaban", withExtension: "icns", subdirectory: "Resources"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        if BoardQA.isActive { Task { await BoardQA.run() } }
    }
}
