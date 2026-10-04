import XCTest
@testable import KabanKit

struct Team2SeededYAML {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func number(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(upperBound))
    }
    mutating func text(_ count: Int) -> String {
        let alphabet = Array("abc09 :,-[]{}#\"'\\\t\nЯé🐗\0")
        return String((0..<count).map { _ in alphabet[number(alphabet.count)] })
    }
    mutating func input(_ index: Int) -> String {
        let value = number(100_000)
        switch index % 12 {
        case 0: return text(number(96))
        case 1: return "key: [\(value), {unicode: 'Яé🐗', empty: []}]"
        case 2: return "key: \(value)\nkey: duplicate"
        case 3: return "key:\n\tchild: \(value)"
        case 4: return "key: &anchor \(value)\ncopy: *anchor"
        case 5: return "key: \"\(text(number(40)))"
        case 6: return "literal: |\n  line \(value)\n  Яé🐗\nfolded: >-\n  first\n  second"
        case 7:
            let depth = 1 + number(24)
            return (0..<depth).map { String(repeating: " ", count: $0 * 2) + "k\($0):" }
                .joined(separator: "\n") + "\n" + String(repeating: " ", count: depth * 2) + "leaf: \(value)"
        case 8: return "key: [" + text(number(80))
        case 9: return "key: '" + String(repeating: "Я🐗", count: 32 + number(256)) + "'"
        case 10:
            let yaml = "key: {value: \(value), list: [one, two]}"
            return String(yaml.prefix(number(yaml.count + 1)))
        default: return "key: \(text(number(80)))\r\nnext: null\n..."
        }
    }
}

final class Team2MiniYAMLFuzzTests: XCTestCase {
    private func outcome(_ text: String) -> Result<YAMLNode, YAMLSyntaxError> {
        do { return .success(try MiniYAML.parse(text)) }
        catch { return .failure(error) }
    }

    func testFiveThousandSeededInputsHaveDeterministicOutcomesAndLocatedErrors() {
        var successes = 0
        var failures = 0
        for seed: UInt64 in [0xB2_2026_1004, 0xCAFE_5000] {
            var generator = Team2SeededYAML(seed: seed)
            var replay = Team2SeededYAML(seed: seed)
            for index in 0..<2_500 {
                let text = generator.input(index)
                let label = "seed=\(seed) index=\(index) yaml=\(text.debugDescription)"
                XCTAssertEqual(text, replay.input(index), label)
                let first = outcome(text)
                XCTAssertEqual(first, outcome(text), label)
                switch first {
                case .success: successes += 1
                case .failure(let error):
                    failures += 1
                    XCTAssertGreaterThan(error.line, 0, label)
                    XCTAssertLessThanOrEqual(error.line, text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).count, label)
                    XCTAssertFalse(error.message.isEmpty, label)
                }
            }
        }
        XCTAssertGreaterThan(successes, 500)
        XCTAssertGreaterThan(failures, 500)
    }

    func testGeneratedQuotedScalarsPreserveUnicodeAndCommentCharacters() throws {
        var generator = Team2SeededYAML(seed: 0xB2_51CA1A)
        for index in 0..<128 {
            let value = "Яé🐗 #,:[]{} ' " + String(generator.number(1_000_000))
            let quoted = value.replacingOccurrences(of: "'", with: "''")
            let node = try MiniYAML.parse("key: '\(quoted)'")
            XCTAssertEqual(node["key"]?.value, .scalar(value, quoted: true), "index=\(index)")
        }
    }

    func testTargetedDeepFlowBlockAndLongScalarsRemainDeterministic() {
        let depth = 64
        let block = (0..<depth).map { String(repeating: " ", count: $0 * 2) + "k\($0):" }
            .joined(separator: "\n") + "\n" + String(repeating: " ", count: depth * 2) + "leaf: ok"
        let flow = "key: " + String(repeating: "[", count: depth) + "ok" + String(repeating: "]", count: depth)
        let long = "key: '" + String(repeating: "x", count: 65_536) + "'"
        for text in [block, flow, long, String(flow.dropLast()), "key: \"\\uD800\"", "key: \"\\u0000\""] {
            let first = outcome(text)
            XCTAssertEqual(first, outcome(text))
            if case .failure(let error) = first { XCTAssertGreaterThan(error.line, 0) }
        }
    }
}
