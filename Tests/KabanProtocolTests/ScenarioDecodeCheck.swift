import Foundation
import XCTest
@testable import KabanProtocol

/// Проверяет, что команды и состояния в сценариях аналитика декодируются типами KabanProtocol.
final class ScenarioDecodeCheck: XCTestCase {
    func testScenariosDecode() throws {
        let dir = try scenariosDirectory()
        let dec = KabanCoding.makeDecoder()
        var problems: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir).sorted() where name.hasSuffix(".json") {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
            let root = try JSONSerialization.jsonObject(with: data)
            func walk(_ v: Any, _ path: String) {
                if let d = v as? [String: Any] {
                    if d["check"] != nil, (d["type"] as? String) != "taskUpdated", d["data"] != nil {
                        let raw = try? JSONSerialization.data(withJSONObject: ["type": d["type"]!, "data": d["data"]!])
                        let okJ = raw.flatMap { try? dec.decode(JournalEvent.self, from: $0) }.map { _ in true } ?? false
                        let okE = raw.flatMap { try? dec.decode(EphemeralEvent.self, from: $0) }.map { _ in true } ?? false
                        if !(okJ || okE) { problems.append("\(name) \(path): событие \(d["type"] ?? "?") не декодируется") }
                    }
                    if (d["type"] as? String) == "taskUpdated", let card = d["data"] as? [String: Any] {
                        do { _ = try dec.decode(TaskCard.self, from: JSONSerialization.data(withJSONObject: card)) }
                        catch { problems.append("\(name) \(path).taskUpdated: \(error)") }
                    }
                    for (k, x) in d {
                        let p = path + "." + k
                        if k == "command", let c = x as? [String: Any], c["protocolVersion"] != nil {
                            do { _ = try dec.decode(CommandEnvelope.self, from: JSONSerialization.data(withJSONObject: c)) }
                            catch { problems.append("\(name) \(p): \(error)") }
                        } else if k == "state", let s = x as? [String: Any] {
                            do { _ = try dec.decode(TaskState.self, from: JSONSerialization.data(withJSONObject: s)) }
                            catch { problems.append("\(name) \(p): \(s)") }
                        }
                        walk(x, p)
                    }
                } else if let a = v as? [Any] { for (i, x) in a.enumerated() { walk(x, "\(path)[\(i)]") } }
            }
            walk(root, "")
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// `KABAN_SCENARIOS`, иначе `Scenarios/M1` в корне репозитория (от `#filePath` вверх).
    private func scenariosDirectory() throws -> String {
        if let env = ProcessInfo.processInfo.environment["KABAN_SCENARIOS"], !env.isEmpty {
            return env
        }
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("Scenarios").appendingPathComponent("M1")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        XCTFail("Нет Scenarios/M1 и не задан KABAN_SCENARIOS")
        struct MissingScenarios: Error {}
        throw MissingScenarios()
    }
}
