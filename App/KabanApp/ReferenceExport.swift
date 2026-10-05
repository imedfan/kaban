import SwiftUI
import AppKit
import CryptoKit

/// Render the actual native views, including every supplied reference state.
@MainActor enum ReferenceExport {
    static func exportAll(to directory: String) async throws {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let requested = CommandLine.arguments.firstIndex(of: "--frame-id").flatMap {
            CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil
        }
        let runtime = [
            ReferenceFrame(id: "runtime/latest-board", width: 1440, height: 900, dark: false, route: "board"),
            ReferenceFrame(id: "runtime/latest-board-dark", width: 1440, height: 900, dark: true, route: "board"),
            ReferenceFrame(id: "runtime/minimum-window", width: 1040, height: 640, dark: false, route: "board")
        ]
        var records: [[String: String]] = []
        for frame in (ReferenceFrame.all + runtime).filter({ requested == nil || requested == $0.id }) {
            let demo = ReferenceDemo()
            demo.dark = frame.dark
            demo.prepareFrame(frame.route)
            if frame.route == "pipeline-invalid" { demo.model = "" }
            let url = root.appendingPathComponent(frame.id + ".png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await capture(ReferenceFrameView(demo: demo, frame: frame)
                .preferredColorScheme(frame.dark ? .dark : .light), width: frame.width, height: frame.height, to: url)
            let data = try Data(contentsOf: url)
            let bitmap = NSBitmapImageRep(data: data)
            records.append(["id": frame.id, "render": url.path, "renderer": "SwiftUI/AppKit",
                "pixels": "\(bitmap?.pixelsWide ?? 0)x\(bitmap?.pixelsHigh ?? 0)",
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
            print("rendered \(frame.id)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: root.appendingPathComponent("frames.json"))
    }
    static func capture<V:View>(_ view:V,width:CGFloat,height:CGFloat,to url:URL) async throws {
        let host=NSHostingView(rootView:view)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        window.contentView=host
        host.frame=NSRect(x:0,y:0,width:width,height:height)
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for:.milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw NSError(domain:"ReferenceExport",code:1)}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw NSError(domain:"ReferenceExport",code:2)}
        try png.write(to:url)
        window.close()
    }
}

@MainActor enum ReferenceNativeSmoke {
    static func run() async throws -> [String] {
        var checks = try await ReferenceDemo.smoke()
        let root = Bundle.main.resourceURL!.appendingPathComponent("Resources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        while let url = files.nextObject() as? URL {
            guard !["html", "css", "js"].contains(url.pathExtension.lowercased()) else {
                throw NSError(domain: "NativeSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Web resource in application: \(url.lastPathComponent)"])
            }
        }
        checks.append("application bundle contains no HTML, CSS or JavaScript")
        let demo = ReferenceDemo()
        let host = NSHostingView(rootView: ReferenceRuntime(demo: demo).frame(width: 1440, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.layoutSubtreeIfNeeded()
        guard host.fittingSize.width >= 1040, host.fittingSize.height >= 640 else {
            throw NSError(domain: "NativeSmoke", code: 2)
        }
        checks.append("main interface is hosted by native NSHostingView")
        return checks
    }
}
