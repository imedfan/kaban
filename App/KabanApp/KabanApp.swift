import SwiftUI
import KabanBoardCore
import Darwin

@main struct KabanApp: App {
    @NSApplicationDelegateAdaptor(ReferenceAppDelegate.self) private var delegate
    @State private var demo = ReferenceDemo()
    var body: some Scene {
        WindowGroup {
            ReferenceRuntime(demo: demo)
                .frame(minWidth: 1040, minHeight: 640)
                .background(ReferenceWindowChrome())

        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Демо") {
                Button("Доска") {demo.inspectedFrame=nil;demo.route="board"}.keyboardShortcut("0")
                Toggle("Тёмная тема",isOn:$demo.dark)
                Toggle("Нативный прототип",isOn:$demo.nativePrototype)
                Button("Логотип и маскоты") {demo.inspectedFrame=nil;demo.route="mascots"}
                Divider()
                ForEach(ReferenceFrame.all) {frame in Button(frame.id){demo.inspectedFrame=frame.id}}
            }
        }
    }
}

@MainActor final class ReferenceAppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification){
        if let url=Bundle.main.url(forResource:"Kaban",withExtension:"icns",subdirectory:"Resources"),let icon=NSImage(contentsOf:url){NSApplication.shared.applicationIconImage=icon}
        if let i=CommandLine.arguments.firstIndex(of:"--demo-smoke"),CommandLine.arguments.count>i+1 {
            Task{do{let output=URL(fileURLWithPath:CommandLine.arguments[i+1]);if FileManager.default.fileExists(atPath:output.path){try FileManager.default.removeItem(at:output)};let checks=try await ReferenceSourceSmoke.run();let data=try JSONSerialization.data(withJSONObject:["result":"passed","checks":checks],options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]))}catch{FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8));Darwin.exit(EXIT_FAILURE)};NSApplication.shared.terminate(nil)};return
        }
        guard let i=CommandLine.arguments.firstIndex(of:"--export-design-frames"),CommandLine.arguments.count>i+1 else{return}
        Task {do{try await ReferenceExport.exportAll(to:CommandLine.arguments[i+1])}catch{FileHandle.standardError.write(Data("export failed: \(error)\n".utf8));Darwin.exit(EXIT_FAILURE)};NSApplication.shared.terminate(nil)}
    }
}
