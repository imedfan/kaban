import Foundation

/// A conservative source locator, not a YAML parser or validator. It patches only
/// unambiguous block keys / single-line flow mappings. Every untouched byte survives.
/// Anchors, tags, complex keys and multiline values stay in the exact YAML editor.
public struct PipelineTextDocument: Sendable {
    public struct Stage: Identifiable, Sendable {
        public let index: Int
        public let id: String
        public let name: String
        public let kind: String
    }
    private struct Node: Sendable {
        let path: String
        let line: Int
        let indent: Int
        let range: Range<Int>
        let block: Bool
        let safe: Bool
    }
    private var lines: [String]
    private var nodes: [Node] = []
    public private(set) var supportsForms = true
    public init(_ source: String) {
        lines = source.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        scan()
    }
    public var stages: [Stage] {
        nodes.filter { $0.path.hasPrefix("stages[") && $0.path.hasSuffix("].id") }.compactMap { node in
            guard let end = node.path.firstIndex(of: "]"), let index = Int(node.path[node.path.index(node.path.startIndex, offsetBy: 7)..<end]),
                  let id = value(node.path) else { return nil }
            let prefix = "stages[\(index)]"
            return Stage(index: index, id: id, name: value(prefix + ".name") ?? id, kind: value(prefix + ".kind") ?? "?")
        }
    }
    public func value(_ path: String) -> String? {
        guard let node = unique(path), !node.block, node.safe else { return nil }
        let raw = String(Array(lines[node.line])[node.range])
        if raw.hasPrefix("\""), let data = raw.data(using: .utf8), let text = try? JSONDecoder().decode(String.self, from: data) { return text }
        if raw.hasPrefix("'"), raw.hasSuffix("'") { return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return raw
    }
    public func canEdit(_ path: String) -> Bool {
        guard supportsForms else { return false }
        guard nodes.filter({ $0.path == path }).count < 2 else { return false }
        if let node = unique(path) { return node.safe && !node.block }
        let parts = path.split(separator: ".").map(String.init)
        for count in stride(from: parts.count - 1, through: 1, by: -1) {
            let parentPath = parts.prefix(count).joined(separator: ".")
            if nodes.filter({ $0.path == parentPath }).count > 1 { return false }
            if let parent = unique(parentPath) {
                return !parts.dropFirst(count).contains(where: { $0.contains("[") }) && parent.safe && (parent.block || isFlowMapping(parent))
            }
        }
        return parts.count == 1 || (!parts[0].contains("[") && unique(parts[0]) == nil) || unique(parts[0])?.block == true
    }
    public func replacing(_ path: String, with value: String, quoted: Bool = false) throws -> String {
        guard canEdit(path), !value.utf8.contains(where: { $0 == 10 || $0 == 13 || $0 == 0 }) else { throw editError() }
        let token = quoted ? Self.quote(value) : value
        var result = lines
        if let node = unique(path) {
            let chars = Array(result[node.line]); result[node.line] = String(chars[..<node.range.lowerBound]) + token + String(chars[node.range.upperBound...])
        } else {
            let parts = path.split(separator: ".").map(String.init)
            var parent: Node?, depth = 0
            for count in stride(from: parts.count - 1, through: 1, by: -1) {
                if let found = unique(parts.prefix(count).joined(separator: ".")) { parent = found; depth = count; break }
            }
            if let parent, isFlowMapping(parent) {
                var addition = token
                for key in parts.dropFirst(depth).reversed() { addition = key + ": " + addition; if key != parts[depth] { addition = "{" + addition + "}" } }
                let chars = Array(result[parent.line])
                let offset = parent.range.upperBound - 1
                let empty = String(chars[(parent.range.lowerBound + 1)..<offset]).trimmingCharacters(in: .whitespaces).isEmpty
                result[parent.line] = String(chars[..<offset]) + (empty ? "" : ", ") + addition + String(chars[offset...])
                return result.joined(separator: "\n")
            }
            var insertion = parent.map { end(of: $0) } ?? result.count - (result.last == "" ? 1 : 0)
            let indent = parent.map { $0.indent + 2 } ?? 0
            let newline = lines.contains(where: { $0.hasSuffix("\r") }) ? "\r" : ""
            for index in depth..<parts.count {
                let leaf = index == parts.count - 1
                let line = String(repeating: " ", count: indent + (index - depth) * 2) + parts[index] + ":" + (leaf ? " " + token : "") + newline
                result.insert(line, at: insertion); insertion += 1
            }
        }
        return result.joined(separator: "\n")
    }
    public func addingStage(id: String, kind: String) throws -> String {
        guard supportsForms, nodes.filter({ $0.path == "stages" }).count <= 1,
              id.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil else { throw editError() }
        guard let root = unique("stages") else {
            return lines.joined(separator: "\n") + (lines.last == "" ? "" : "\n") + "stages:\n  - id: \(id)\n    name: \(Self.quote(id))\n    kind: \(kind)\n"
        }
        guard root.block, root.safe else { throw editError() }
        var result = lines
        let suffix = lines.contains(where: { $0.hasSuffix("\r") }) ? "\r" : ""
        let content = ["  - id: \(id)", "    name: \(Self.quote(id))", "    kind: \(kind)"].map { $0 + suffix }
        result.insert(contentsOf: content, at: end(of: root))
        return result.joined(separator: "\n")
    }
    public func removingStage(index: Int) throws -> String {
        guard supportsForms, let node = unique("stages[\(index)]"), node.safe else { throw editError() }
        var result = lines; result.removeSubrange(node.line..<end(of: node))
        return result.joined(separator: "\n")
    }
    public static func quote(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
    private func unique(_ path: String) -> Node? {
        let matches = nodes.filter { $0.path == path }; return matches.count == 1 ? matches[0] : nil
    }
    private func isFlowMapping(_ node: Node) -> Bool {
        let text = String(Array(lines[node.line])[node.range])
        return text.hasPrefix("{") && text.hasSuffix("}")
    }
    public func returnIndices(stage: Int) -> [Int] {
        let prefix = "stages[\(stage)].returns_to["
        return Array(Set(nodes.compactMap { node in
            guard node.path.hasPrefix(prefix), let end = node.path.dropFirst(prefix.count).firstIndex(of: "]") else { return nil }
            return Int(node.path[node.path.index(node.path.startIndex, offsetBy: prefix.count)..<end])
        })).sorted()
    }
    private func end(of node: Node) -> Int {
        var end = node.line + 1
        while end < lines.count {
            let text = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !text.hasPrefix("#") && lines[end].prefix(while: { $0 == " " }).count <= node.indent { break }
            end += 1
        }
        // Keep trailing comments and EOF separator with their original owner.
        while end > node.line + 1 {
            let trailing = lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty && !trailing.hasPrefix("#") { break }
            end -= 1
        }
        return end
    }
    private func editError() -> NSError { NSError(domain: "PipelineText", code: 1, userInfo: [NSLocalizedDescriptionKey: "Эта конструкция редактируется в YAML. Исходный текст сохранён."]) }
    private mutating func scan() {
        struct Frame { var indent: Int; var path: String; var next = 0 }
        var stack: [Frame] = [], floor: Int?
        for lineIndex in lines.indices {
            let chars = Array(lines[lineIndex]), indent = chars.prefix(while: { $0 == " " }).count
            let text = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if let blockFloor = floor, indent > blockFloor { continue }; floor = nil
            if text == "---" || text == "..." || text.hasPrefix("%") || chars.contains("\t") { supportsForms = false; continue }
            while stack.last.map({ $0.indent >= indent }) == true { stack.removeLast() }
            var offset = indent, parent = stack.last?.path ?? "", keyIndent = indent
            if text.hasPrefix("- ") {
                guard !stack.isEmpty else { supportsForms = false; continue }
                let index = stack[stack.count - 1].next; stack[stack.count - 1].next += 1
                parent += "[\(index)]"; keyIndent += 2; offset += 2
                let item = String(chars[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let itemEnd = commentEnd(chars, from: offset)
                let flowItem = String(chars[offset..<itemEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                var itemUpper = itemEnd
                while itemUpper > offset && chars[itemUpper - 1].isWhitespace { itemUpper -= 1 }
                nodes.append(Node(path: parent, line: lineIndex, indent: indent, range: offset..<itemUpper, block: !flowItem.hasPrefix("{"), safe: true))
                stack.append(Frame(indent: indent, path: parent))
                if flowItem.hasPrefix("{"), flowItem.hasSuffix("}") {
                    var end = itemEnd
                    while end > offset && chars[end - 1].isWhitespace { end -= 1 }
                    flow(chars, range: (offset + 1)..<(end - 1), path: parent, line: lineIndex, indent: keyIndent)
                    continue
                }
                // Scalar sequence entries (gates, MCP, inputs) stay opaque.
                if !item.contains(":") || item.hasPrefix("\"") || item.hasPrefix("'") { continue }
            }
            guard let colon = chars[offset...].firstIndex(of: ":") else { supportsForms = false; continue }
            let key = String(chars[offset..<colon])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { supportsForms = false; continue }
            let path = parent.isEmpty ? key : parent + "." + key
            var start = colon + 1; while start < chars.count && chars[start] == " " { start += 1 }
            var end = commentEnd(chars, from: start)
            while end > start && (chars[end - 1] == " " || chars[end - 1] == "\r") { end -= 1 }
            let raw = String(chars[start..<end])
            let next = lines.dropFirst(lineIndex + 1).first { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return !t.isEmpty && !t.hasPrefix("#") }
            let block = raw.isEmpty && (next.map { $0.prefix(while: { $0 == " " }).count > keyIndent } ?? false)
            let safe = !raw.hasPrefix("&") && !raw.hasPrefix("*") && !raw.hasPrefix("!") && !raw.hasPrefix("|") && !raw.hasPrefix(">")
            if raw.hasPrefix("&") || raw.hasPrefix("*") || raw.hasPrefix("!") { supportsForms = false }
            nodes.append(Node(path: path, line: lineIndex, indent: keyIndent, range: start..<end, block: block, safe: safe))
            if raw.hasPrefix("|") || raw.hasPrefix(">") { floor = keyIndent }
            if raw.hasPrefix("{") && raw.hasSuffix("}") { flow(chars, range: (start + 1)..<(end - 1), path: path, line: lineIndex, indent: keyIndent) }
            if raw.hasPrefix("[") && raw.hasSuffix("]") { flowSequence(chars, range: (start + 1)..<(end - 1), path: path, line: lineIndex, indent: keyIndent) }
            stack.append(Frame(indent: keyIndent, path: path))
        }
    }
    private func commentEnd(_ chars: [Character], from start: Int) -> Int {
        var quote: Character?, escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if escaped { escaped = false; continue }
            if c == "\\" && quote == "\"" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#", i == start || chars[i - 1].isWhitespace { return i }
        }
        return chars.count
    }
    private mutating func flow(_ chars: [Character], range: Range<Int>, path: String, line: Int, indent: Int) {
        var quote: Character?, escaped = false, nesting = 0, start = range.lowerBound, spans: [Range<Int>] = []
        for i in range {
            let c = chars[i]
            if escaped { escaped = false; continue }
            if c == "\\" && quote == "\"" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "{" || c == "[" { nesting += 1 }; if c == "}" || c == "]" { nesting -= 1 }
            if c == "," && nesting == 0 { spans.append(start..<i); start = i + 1 }
        }
        spans.append(start..<range.upperBound)
        for span in spans {
            var start = span.lowerBound, end = span.upperBound
            while start < end && chars[start].isWhitespace { start += 1 }
            guard let colon = chars[start..<end].firstIndex(of: ":") else { continue }
            let key = String(chars[start..<colon]).trimmingCharacters(in: .whitespaces)
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { continue }
            start = colon + 1; while start < end && chars[start].isWhitespace { start += 1 }; while end > start && chars[end - 1].isWhitespace { end -= 1 }
            let raw = String(chars[start..<end]), child = path + "." + key
            nodes.append(Node(path: child, line: line, indent: indent, range: start..<end, block: false,
                              safe: !raw.hasPrefix("&") && !raw.hasPrefix("*") && !raw.hasPrefix("!")))
            if raw.hasPrefix("{") && raw.hasSuffix("}") { flow(chars, range: (start + 1)..<(end - 1), path: child, line: line, indent: indent) }
            if raw.hasPrefix("[") && raw.hasSuffix("]") { flowSequence(chars, range: (start + 1)..<(end - 1), path: child, line: line, indent: indent) }
        }
    }
    private mutating func flowSequence(_ chars: [Character], range: Range<Int>, path: String, line: Int, indent: Int) {
        var nesting = 0, quote: Character?, escaped = false, start = range.lowerBound, index = 0
        for i in range.lowerBound...range.upperBound {
            if i == range.upperBound || (chars[i] == "," && nesting == 0 && quote == nil) {
                var lower = start, upper = i
                while lower < upper && chars[lower].isWhitespace { lower += 1 }
                while upper > lower && chars[upper - 1].isWhitespace { upper -= 1 }
                if lower < upper, chars[lower] == "{", chars[upper - 1] == "}" {
                    let itemPath = path + "[\(index)]"
                    nodes.append(Node(path: itemPath, line: line, indent: indent, range: lower..<upper, block: false, safe: true))
                    flow(chars, range: (lower + 1)..<(upper - 1), path: itemPath, line: line, indent: indent)
                }
                start = i + 1; index += 1
                continue
            }
            let c = chars[i]
            if escaped { escaped = false; continue }
            if c == "\\" && quote == "\"" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "{" || c == "[" { nesting += 1 }
            if c == "}" || c == "]" { nesting -= 1 }
        }
    }
}
