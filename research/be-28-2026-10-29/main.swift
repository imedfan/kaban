import Foundation

let files = FileManager.default
let root = URL(fileURLWithPath: "/tmp/kaban-be28-free-" + UUID().uuidString)
let clone = root.appendingPathComponent("clone")
let home = root.appendingPathComponent("home")
let userHome = files.homeDirectoryForCurrentUser
let cli = CommandLine.arguments.dropFirst().first ?? userHome.appendingPathComponent(".local/bin/cursor-agent").path
try files.createDirectory(at: clone.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
try "{\"mcpServers\":{\"kaban\":{\"url\":\"http://127.0.0.1:43191/mcp\"}}}".write(to: clone.appendingPathComponent(".cursor/mcp.json"), atomically: true, encoding: .utf8)
let environment = try CursorRunHome.environment(ProcessInfo.processInfo.environment, home: home)
let scratch = URL(fileURLWithPath: environment["TMPDIR"]!)
defer { try? files.removeItem(at: root) }
var facts: [[String: Any]] = []
for args in [["--version"], ["status", "--format", "json"], ["mcp", "list"]] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: SeatbeltProfile.executable)
    p.arguments = SeatbeltProfile.arguments(clone: clone.path, scratch: scratch.path, runHome: home.path, realHome: userHome.path,
        repository: root.appendingPathComponent("main-repository").path, cli: cli, mcpPort: 43191, command: [cli] + args)
    p.environment = environment
    p.currentDirectoryURL = clone
    let outURL = root.appendingPathComponent(args[0] + ".out"), errURL = root.appendingPathComponent(args[0] + ".err")
    files.createFile(atPath: outURL.path, contents: nil); files.createFile(atPath: errURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
    p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
    try p.run()
    let deadline = Date().addingTimeInterval(20)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { p.terminate() }
    p.waitUntilExit()
    try out.close(); try err.close()
    let stdout = try Data(contentsOf: outURL), stderr = try String(contentsOf: errURL, encoding: .utf8)
    var fact: [String: Any] = ["command": args, "exit": p.terminationStatus, "stderrBytes": stderr.utf8.count]
    if args[0] == "status" {
        let status = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
        fact["isAuthenticated"] = status?["isAuthenticated"] ?? NSNull()
    } else if args[0] == "mcp" {
        fact["boardListed"] = String(decoding: stdout, as: UTF8.self).contains("kaban:")
    } else { fact["version"] = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
    facts.append(fact)
}
let data = try JSONSerialization.data(withJSONObject: ["facts": facts, "paidPrompts": 0], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
