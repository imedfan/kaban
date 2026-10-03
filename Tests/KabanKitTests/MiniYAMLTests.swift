import XCTest
@testable import KabanKit

final class MiniYAMLTests: XCTestCase {
    func scalar(_ n: YAMLNode?) -> String? { if case .scalar(let s, _)? = n?.value { return s }; return nil }
    func seq(_ n: YAMLNode?) -> [String] {
        guard case .sequence(let items)? = n?.value else { return [] }
        return items.compactMap { scalar($0) }
    }

    func testBlockAndFlow() throws {
        let doc = try MiniYAML.parse("""
        ---
        # comment
        a: 1   # trailing
        b: "x # not a comment"
        c: 'it''s'
        list:
          - one
          - "two"
        compact:
        - x
        - y
        flow: [a, "b, c", [d]]
        map: { k: v, n: { m: 1 }, e: [] }
        items:
          - id: first
            name: First
          - id: second
          -
            id: third
        empty:
        url: http://example.com:8080/x
        """)
        XCTAssertEqual(scalar(doc["a"]), "1")
        XCTAssertEqual(scalar(doc["b"]), "x # not a comment")
        XCTAssertEqual(scalar(doc["c"]), "it's")
        XCTAssertEqual(seq(doc["list"]), ["one", "two"])
        XCTAssertEqual(seq(doc["compact"]), ["x", "y"])
        guard case .sequence(let flow)? = doc["flow"]?.value else { return XCTFail() }
        XCTAssertEqual(flow.count, 3)
        XCTAssertEqual(scalar(flow[1]), "b, c")
        XCTAssertEqual(scalar(doc["map"]?["n"]?["m"]), "1")
        XCTAssertEqual(seq(doc["map"]?["e"]), [])
        guard case .sequence(let items)? = doc["items"]?.value else { return XCTFail() }
        XCTAssertEqual(items.map { scalar($0["id"]) }, ["first", "second", "third"])
        XCTAssertEqual(scalar(items[0]["name"]), "First")
        XCTAssertEqual(items[1].line, 17)
        XCTAssertTrue(doc["empty"]!.isNull)
        XCTAssertEqual(scalar(doc["url"]), "http://example.com:8080/x")
    }

    func testMultilineFlowAndBlockScalars() throws {
        let doc = try MiniYAML.parse("""
        gates: [
          "make build",
          make test,
        ]
        script: |
          line one
            indented
          line three
        folded: >-
          a
          b

          c
        after: ok
        """)
        XCTAssertEqual(seq(doc["gates"]), ["make build", "make test"])
        XCTAssertEqual(scalar(doc["script"]), "line one\n  indented\nline three\n")
        XCTAssertEqual(scalar(doc["folded"]), "a b\nc")
        XCTAssertEqual(scalar(doc["after"]), "ok")
    }

    func testEscapes() throws {
        let doc = try MiniYAML.parse(#"s: "tab\tnew\nquote\" \u00e9""#)
        XCTAssertEqual(scalar(doc["s"]), "tab\tnew\nquote\" é")
    }

    func testErrors() {
        func line(_ text: String) -> Int? {
            do { _ = try MiniYAML.parse(text); return nil } catch { return error.line }
        }
        XCTAssertEqual(line("a: 1\na: 2"), 2)                       // duplicate key
        XCTAssertEqual(line("a: 1\n\tb: 2"), 2)                      // tab indentation
        XCTAssertEqual(line("a: &x 1"), 1)                           // anchors
        XCTAssertEqual(line("a: [1, 2"), 1)                          // unterminated flow
        XCTAssertEqual(line("a: 1\n   b: 2"), 2)                     // bad indentation
        XCTAssertEqual(line("a: \"open"), 1)                         // unterminated quote
        XCTAssertEqual(line("a: 1\n---\nb: 2"), 2)                   // multiple documents
        XCTAssertEqual(line("a:\n  - x\n  y: 1"), 3)                 // mixed sequence/mapping
        XCTAssertEqual(line("? complex\n: v"), 1)
        XCTAssertNil(line(""))
    }
}
