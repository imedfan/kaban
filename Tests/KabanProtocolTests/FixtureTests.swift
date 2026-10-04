import Foundation
import XCTest
@testable import KabanProtocol

/// Golden-фикстуры в `Fixtures/`. Перезаписать: `KABAN_RECORD_FIXTURES=1 swift test --filter FixtureTests`.
final class FixtureTests: XCTestCase {
    let encoder = KabanCoding.makeEncoder(pretty: true)
    let decoder = KabanCoding.makeDecoder()
    var recording: Bool { ProcessInfo.processInfo.environment["KABAN_RECORD_FIXTURES"] == "1" }

    var sourceDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }

    func check<T: Codable & Equatable>(_ name: String, _ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try encoder.encode(value) + Data("\n".utf8)
        let url = sourceDir.appendingPathComponent(name)
        if recording {
            try encoded.write(to: url)
            return
        }
        guard let bundled = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            return XCTFail("Нет фикстуры \(name), запусти с KABAN_RECORD_FIXTURES=1", file: file, line: line)
        }
        let data = try Data(contentsOf: bundled)
        XCTAssertEqual(try decoder.decode(T.self, from: data), value, "\(name): декодирование разошлось с эталоном", file: file, line: line)
        // Сравниваем JSON по смыслу, а не побайтно: отступы и порядок ключей зависят от версии Foundation.
        func canonical(_ d: Data) throws -> String {
            let object = try JSONSerialization.jsonObject(with: d)
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(try canonical(data), try canonical(encoded),
                      "\(name): формат на проводе изменился; если намеренно — перезапиши фикстуры и предупреди фронт и бэк", file: file, line: line)
    }

    func testSnapshot() throws { try check("snapshot.json", Samples.snapshot) }
    func testJournalEvents() throws { try check("journal-events.json", Samples.events) }
    func testEphemeralEvents() throws { try check("ephemeral-events.json", Samples.ephemeral) }
    func testCommands() throws { try check("commands.json", Samples.commands) }
}
