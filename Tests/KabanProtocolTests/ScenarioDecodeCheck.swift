import Foundation
import XCTest
@testable import KabanProtocol

/// Проверяет, что команды, события и состояния в сценариях M1 декодируются типами KabanProtocol.
/// Без `KABAN_SCENARIOS` тест пропускается (локально и до появления `Scenarios/M1` в main).
/// Если переменная задана, папка обязана существовать и содержать `.json` прямо в ней (в CI — `Scenarios/M1`),
/// иначе тест падает, а не проходит вхолостую.
final class ScenarioDecodeCheck: XCTestCase {
    func testScenariosDecode() throws {
        guard let dir = ProcessInfo.processInfo.environment["KABAN_SCENARIOS"] else { throw XCTSkip("KABAN_SCENARIOS не задан") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return XCTFail("KABAN_SCENARIOS=\(dir): папки нет")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).sorted().filter { $0.hasSuffix(".json") }
        guard !files.isEmpty else {
            return XCTFail("KABAN_SCENARIOS=\(dir): нет .json прямо в папке (нужна Scenarios/M1, а не корень Scenarios)")
        }
        let dec = KabanCoding.makeDecoder()
        var problems: [String] = []
        for name in files {
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
}
