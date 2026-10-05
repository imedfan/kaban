import SwiftUI
import KabanBoardCore
import Darwin

@main struct KabanApp: App {
    @NSApplicationDelegateAdaptor(ReferenceAppDelegate.self) private var delegate
    @State private var demo = ReferenceDemo()
    var body: some Scene {
        WindowGroup(id: "board") {
            ReferenceRuntime(demo: demo)
                .frame(minWidth: 1040, minHeight: 640)
                .background(ReferenceWindowChrome())

        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая задача") { demo.draftTitle = ""; demo.draftBody = ""; demo.sheet = "create" }.keyboardShortcut("n")
                Button("Добавить проект") { demo.identityMode = 0; demo.sheet = "add" }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Поиск задач") { demo.sheet = "search" }.keyboardShortcut("f")
            }

            CommandMenu("Демо") {
                Button("Доска") {demo.inspectedFrame=nil;demo.prepareFrame("board");demo.route="board"}.keyboardShortcut("0")
                Toggle("Тёмная тема",isOn:$demo.dark)
                Button("Логотип и маскоты") {demo.inspectedFrame=nil;demo.route="mascots"}
                Divider()
                ForEach(ReferenceFrame.all) {frame in Button(frame.id){demo.dark=frame.dark;demo.prepareFrame(frame.route);demo.inspectedFrame=frame.id}}
            }
        }
        MenuBarExtra("Kaban", systemImage: "rectangle.split.3x1") { ReferenceMenuBar(demo: demo) }
            .menuBarExtraStyle(.window)
    }
}

@MainActor final class ReferenceAppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification){
        if let url=Bundle.main.url(forResource:"Kaban",withExtension:"icns",subdirectory:"Resources"),let icon=NSImage(contentsOf:url){NSApplication.shared.applicationIconImage=icon}
        if let i=CommandLine.arguments.firstIndex(of:"--demo-smoke"),CommandLine.arguments.count>i+1 {
            Task{do{let output=URL(fileURLWithPath:CommandLine.arguments[i+1]);if FileManager.default.fileExists(atPath:output.path){try FileManager.default.removeItem(at:output)};let checks=try await ReferenceNativeSmoke.run();let data=try JSONSerialization.data(withJSONObject:["result":"passed","checks":checks],options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]))}catch{FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8));Darwin.exit(EXIT_FAILURE)};NSApplication.shared.terminate(nil)};return
        }
        guard let i=CommandLine.arguments.firstIndex(of:"--export-design-frames"),CommandLine.arguments.count>i+1 else{return}
        Task {do{try await ReferenceExport.exportAll(to:CommandLine.arguments[i+1])}catch{FileHandle.standardError.write(Data("export failed: \(error)\n".utf8));Darwin.exit(EXIT_FAILURE)};NSApplication.shared.terminate(nil)}
    }
}
