import Foundation

/// A parsed YAML node with the 1-based source line it started on (for error messages).
public struct YAMLNode: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        /// Scalar text. `quoted` scalars are always strings; plain ones may be numbers, booleans or null.
        case scalar(String, quoted: Bool)
        case sequence([YAMLNode])
        /// Ordered entries; duplicate keys are rejected by the parser.
        case mapping([YAMLEntry])
    }

    public var value: Value
    public var line: Int

    public init(_ value: Value, line: Int) { self.value = value; self.line = line }

    /// Plain `null`, `~` or an empty value.
    public var isNull: Bool {
        if case .scalar(let s, let quoted) = value, !quoted { return s.isEmpty || s == "~" || s == "null" || s == "Null" || s == "NULL" }
        return false
    }

    public subscript(key: String) -> YAMLNode? {
        guard case .mapping(let entries) = value else { return nil }
        return entries.first { $0.key == key }?.value
    }
}

public struct YAMLEntry: Hashable, Sendable {
    public var key: String
    public var keyLine: Int
    public var value: YAMLNode
    public init(key: String, keyLine: Int, value: YAMLNode) { self.key = key; self.keyLine = keyLine; self.value = value }
}

public struct YAMLSyntaxError: Error, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
    public var description: String { "line \(line): \(message)" }
}

/// Minimal, dependency-free YAML reader for `.kaban/pipeline.yaml`.
///
/// Supported subset (enough for hand-written config files):
/// block mappings and sequences (including `- key: value` items and compact `key:\n- item`),
/// flow collections `[a, b]` / `{ a: 1 }` (nested, may span lines), plain / single- / double-quoted scalars,
/// literal `|` and folded `>` block scalars with `-`/`+` chomping, `#` comments, a leading `---`.
/// Not supported (reported as syntax errors): anchors/aliases, tags, complex `?` keys, multiple documents, tab indentation.
/// The tree is format-neutral, so swapping in Yams later only means producing `YAMLNode` from it.
public enum MiniYAML {
    public static func parse(_ text: String) throws(YAMLSyntaxError) -> YAMLNode {
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }
}

private struct Line {
    var number: Int
    var indent: Int
    /// Content after indentation, comment stripped, trailing whitespace trimmed. Empty for blank/comment lines.
    var text: String
    /// The raw line without the newline (needed for block scalars).
    var raw: String
}

private struct Parser {
    var lines: [Line]
    var index = 0

    init(text: String) {
        var result: [Line] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for (i, rawSub) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let raw = String(rawSub)
            let indent = raw.prefix { $0 == " " }.count
            let body = String(raw.dropFirst(indent))
            result.append(Line(number: i + 1, indent: indent, text: Parser.stripComment(body), raw: raw))
        }
        lines = result
    }

    static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        var prev: Character = " "
        var out = ""
        var escaped = false
        for ch in s {
            if inDouble {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" { inSingle = false }
            } else if ch == "#" && (prev == " " || prev == "\t" || out.isEmpty) {
                break
            } else if ch == "\"" && (out.isEmpty || " [{,:-".contains(prev)) {
                inDouble = true
            } else if ch == "'" && (out.isEmpty || " [{,:-".contains(prev)) {
                inSingle = true
            }
            out.append(ch)
            prev = ch
        }
        while let last = out.last, last == " " || last == "\t" { out.removeLast() }
        return out
    }

    // MARK: Navigation

    mutating func skipBlank() {
        while index < lines.count, lines[index].text.isEmpty { index += 1 }
    }

    var current: Line? {
        mutating get { skipBlank(); return index < lines.count ? lines[index] : nil }
    }

    // MARK: Document

    mutating func parseDocument() throws(YAMLSyntaxError) -> YAMLNode {
        for line in lines {
            if line.raw.hasPrefix("\t") || (line.raw.prefix { $0 == " " || $0 == "\t" }.contains("\t") && !line.text.isEmpty) {
                throw YAMLSyntaxError(line: line.number, message: "tabs are not allowed for indentation")
            }
        }
        if let first = current, first.indent == 0, first.text == "---" || first.text.hasPrefix("--- ") {
            if first.text != "---" { throw YAMLSyntaxError(line: first.number, message: "content after '---' is not supported") }
            index += 1
        }
        guard let first = current else { return YAMLNode(.scalar("", quoted: false), line: 1) }
        let node = try parseBlock(indent: first.indent)
        if let extra = current {
            if extra.text == "---" || extra.text == "..." {
                throw YAMLSyntaxError(line: extra.number, message: "multiple documents are not supported")
            }
            throw YAMLSyntaxError(line: extra.number, message: "unexpected content (check indentation)")
        }
        return node
    }

    /// Parses the block node whose first line is the current line with exactly `indent`.
    mutating func parseBlock(indent: Int) throws(YAMLSyntaxError) -> YAMLNode {
        guard let line = current else { return YAMLNode(.scalar("", quoted: false), line: lines.last?.number ?? 1) }
        if Parser.isSequenceItem(line.text) { return try parseSequence(indent: indent) }
        if try Parser.splitKey(line.text, line: line.number) != nil { return try parseMapping(indent: indent) }
        // A lone scalar or flow collection.
        index += 1
        let node = try parseInlineValue(line.text, line: line.number, indent: indent)
        if let next = current, next.indent > indent {
            throw YAMLSyntaxError(line: next.number, message: "unexpected indentation (multi-line plain scalars are not supported)")
        }
        return node
    }

    static func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    mutating func parseSequence(indent: Int) throws(YAMLSyntaxError) -> YAMLNode {
        let startLine = current!.number
        var items: [YAMLNode] = []
        while let line = current, line.indent == indent, Parser.isSequenceItem(line.text) {
            let rest = String(line.text.dropFirst(1))
            let offset = rest.prefix { $0 == " " }.count
            let content = String(rest.dropFirst(offset))
            if content.isEmpty {
                index += 1
                if let next = current, next.indent > indent {
                    items.append(try parseBlock(indent: next.indent))
                } else {
                    items.append(YAMLNode(.scalar("", quoted: false), line: line.number))
                }
                continue
            }
            // Re-interpret the rest of the line as a block starting at a deeper virtual indent.
            let virtualIndent = indent + 1 + offset
            var startsBlock = Parser.isSequenceItem(content)
            if !startsBlock { startsBlock = try Parser.splitKey(content, line: line.number) != nil }
            if startsBlock {
                lines[index] = Line(number: line.number, indent: virtualIndent, text: content, raw: line.raw)
                items.append(try parseBlock(indent: virtualIndent))
            } else {
                index += 1
                items.append(try parseInlineValue(content, line: line.number, indent: virtualIndent))
            }
            if let next = current, next.indent > indent {
                throw YAMLSyntaxError(line: next.number, message: "unexpected indentation inside sequence")
            }
        }
        if let next = current, next.indent > indent {
            throw YAMLSyntaxError(line: next.number, message: "unexpected indentation")
        }
        return YAMLNode(.sequence(items), line: startLine)
    }

    mutating func parseMapping(indent: Int) throws(YAMLSyntaxError) -> YAMLNode {
        let startLine = current!.number
        var entries: [YAMLEntry] = []
        var seen = Set<String>()
        while let line = current, line.indent == indent {
            if Parser.isSequenceItem(line.text) {
                throw YAMLSyntaxError(line: line.number, message: "sequence item where a mapping key was expected")
            }
            guard let (key, rest) = try Parser.splitKey(line.text, line: line.number) else {
                throw YAMLSyntaxError(line: line.number, message: "expected 'key: value'")
            }
            if !seen.insert(key).inserted { throw YAMLSyntaxError(line: line.number, message: "duplicate key '\(key)'") }
            index += 1
            let value: YAMLNode
            if rest.isEmpty {
                if let next = current, next.indent > indent {
                    value = try parseBlock(indent: next.indent)
                } else if let next = current, next.indent == indent, Parser.isSequenceItem(next.text) {
                    value = try parseSequence(indent: indent)
                } else {
                    value = YAMLNode(.scalar("", quoted: false), line: line.number)
                }
            } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                value = try parseBlockScalar(header: rest, line: line.number, parentIndent: indent)
            } else {
                value = try parseInlineValue(rest, line: line.number, indent: indent)
                if let next = current, next.indent > indent {
                    throw YAMLSyntaxError(line: next.number, message: "unexpected indentation after '\(key):' (multi-line plain scalars are not supported)")
                }
            }
            entries.append(YAMLEntry(key: key, keyLine: line.number, value: value))
        }
        if let next = current, next.indent > indent {
            throw YAMLSyntaxError(line: next.number, message: "unexpected indentation")
        }
        return YAMLNode(.mapping(entries), line: startLine)
    }

    /// Splits `key: rest`. Returns nil when the text is not a mapping entry.
    static func splitKey(_ text: String, line: Int) throws(YAMLSyntaxError) -> (String, String)? {
        guard let first = text.first else { return nil }
        if first == "[" || first == "{" { return nil }
        if first == "?" && (text.count == 1 || text.dropFirst().first == " ") {
            throw YAMLSyntaxError(line: line, message: "complex keys ('?') are not supported")
        }
        if first == "\"" || first == "'" {
            var scanner = FlowScanner(text: text, line: line)
            let key = try scanner.parseQuoted()
            scanner.skipSpaces()
            guard scanner.peek == ":" else { return nil }
            scanner.advance()
            guard scanner.atEnd || scanner.peek == " " else { return nil }
            return (key, scanner.rest.trimmingCharacters(in: .whitespaces))
        }
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == ":" && (i + 1 == chars.count || chars[i + 1] == " ") {
                let key = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                if key.isEmpty { return nil }
                return (key, String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            }
            i += 1
        }
        return nil
    }

    mutating func parseInlineValue(_ text: String, line: Int, indent: Int) throws(YAMLSyntaxError) -> YAMLNode {
        guard let first = text.first else { return YAMLNode(.scalar("", quoted: false), line: line) }
        if first == "&" || first == "*" { throw YAMLSyntaxError(line: line, message: "anchors and aliases are not supported") }
        if first == "!" { throw YAMLSyntaxError(line: line, message: "tags are not supported") }
        var source = text
        if first == "[" || first == "{" {
            // Flow collections may continue on following lines until brackets balance.
            while !Parser.isBalanced(source) {
                guard index < lines.count else { throw YAMLSyntaxError(line: line, message: "unterminated flow collection") }
                let next = lines[index]
                index += 1
                if next.text.isEmpty { continue }
                source += " " + next.text
            }
        }
        var scanner = FlowScanner(text: source, line: line)
        let node = try scanner.parseValue(inFlow: false)
        scanner.skipSpaces()
        if !scanner.atEnd { throw YAMLSyntaxError(line: line, message: "unexpected characters after value: '\(scanner.rest)'") }
        return node
    }

    static func isBalanced(_ s: String) -> Bool {
        var depth = 0
        var inSingle = false, inDouble = false, escaped = false
        for ch in s {
            if inDouble {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inDouble = false }
                continue
            }
            if inSingle { if ch == "'" { inSingle = false }; continue }
            switch ch {
            case "\"": inDouble = true
            case "'": inSingle = true
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth <= 0 && !inSingle && !inDouble
    }

    mutating func parseBlockScalar(header: String, line: Int, parentIndent: Int) throws(YAMLSyntaxError) -> YAMLNode {
        let folded = header.hasPrefix(">")
        var chomp: Character = " "
        for ch in header.dropFirst() {
            if ch == "-" || ch == "+" { chomp = ch }
            else if ch.isNumber { throw YAMLSyntaxError(line: line, message: "explicit indentation indicators are not supported") }
            else { throw YAMLSyntaxError(line: line, message: "invalid block scalar header '\(header)'") }
        }
        var body: [String] = []
        var blockIndent: Int?
        while index < lines.count {
            let l = lines[index]
            let isBlank = l.raw.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank { body.append(""); index += 1; continue }
            let ind = l.raw.prefix { $0 == " " }.count
            if blockIndent == nil {
                guard ind > parentIndent else { break }
                blockIndent = ind
            }
            guard ind >= blockIndent! else { break }
            body.append(String(l.raw.dropFirst(blockIndent!)))
            index += 1
        }
        // Trailing blank lines belong to chomping, not to the content.
        var trailing = 0
        while let last = body.last, last.isEmpty { body.removeLast(); trailing += 1 }
        var text: String
        if folded {
            text = ""
            for (i, l) in body.enumerated() {
                if l.isEmpty { text += "\n"; continue }
                if i > 0 && !body[i - 1].isEmpty {
                    text += (l.hasPrefix(" ") || body[i - 1].hasPrefix(" ")) ? "\n" : " "
                }
                text += l
            }
        } else {
            text = body.joined(separator: "\n")
        }
        switch chomp {
        case "-": break
        case "+": if !body.isEmpty { text += String(repeating: "\n", count: trailing + 1) }
        default: if !body.isEmpty { text += "\n" }
        }
        return YAMLNode(.scalar(text, quoted: true), line: line)
    }
}

/// Character scanner for flow collections and quoted scalars on a single logical line.
private struct FlowScanner {
    let chars: [Character]
    var pos = 0
    let line: Int

    init(text: String, line: Int) { chars = Array(text); self.line = line }

    var atEnd: Bool { pos >= chars.count }
    var peek: Character? { atEnd ? nil : chars[pos] }
    var rest: String { atEnd ? "" : String(chars[pos...]) }
    mutating func advance() { pos += 1 }
    mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { pos += 1 } }

    func error(_ message: String) -> YAMLSyntaxError { YAMLSyntaxError(line: line, message: message) }

    mutating func parseValue(inFlow: Bool) throws(YAMLSyntaxError) -> YAMLNode {
        skipSpaces()
        guard let c = peek else { return YAMLNode(.scalar("", quoted: false), line: line) }
        switch c {
        case "[": return try parseFlowSequence()
        case "{": return try parseFlowMapping()
        case "\"", "'": return YAMLNode(.scalar(try parseQuoted(), quoted: true), line: line)
        case "&", "*": throw error("anchors and aliases are not supported")
        case "!": throw error("tags are not supported")
        default: return YAMLNode(.scalar(parsePlain(inFlow: inFlow, isKey: false), quoted: false), line: line)
        }
    }

    mutating func parsePlain(inFlow: Bool, isKey: Bool) -> String {
        var out = ""
        while let c = peek {
            if inFlow && (c == "," || c == "]" || c == "}") { break }
            if (inFlow || isKey) && c == ":" {
                let next = pos + 1 < chars.count ? chars[pos + 1] : " "
                if next == " " || next == "," || next == "]" || next == "}" || (isKey && pos + 1 >= chars.count) { break }
            }
            out.append(c)
            pos += 1
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    mutating func parseQuoted() throws(YAMLSyntaxError) -> String {
        let quote = peek!
        advance()
        var out = ""
        while let c = peek {
            advance()
            if quote == "'" {
                if c == "'" {
                    if peek == "'" { out.append("'"); advance(); continue }
                    return out
                }
                out.append(c)
            } else {
                if c == "\"" { return out }
                if c == "\\" {
                    guard let e = peek else { break }
                    advance()
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "0": out.append("\0")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case " ": out.append(" ")
                    case "u":
                        var hex = ""
                        for _ in 0..<4 { if let h = peek { hex.append(h); advance() } }
                        guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { throw error("invalid \\u escape") }
                        out.unicodeScalars.append(scalar)
                    default: throw error("unsupported escape '\\\(e)'")
                    }
                    continue
                }
                out.append(c)
            }
        }
        throw error("unterminated quoted string")
    }

    mutating func parseFlowSequence() throws(YAMLSyntaxError) -> YAMLNode {
        advance() // [
        var items: [YAMLNode] = []
        skipSpaces()
        if peek == "]" { advance(); return YAMLNode(.sequence(items), line: line) }
        while true {
            items.append(try parseValue(inFlow: true))
            skipSpaces()
            guard let c = peek else { throw error("unterminated '['") }
            advance()
            if c == "]" { break }
            if c != "," { throw error("expected ',' or ']' in flow sequence") }
            skipSpaces()
            if peek == "]" { advance(); break } // trailing comma
        }
        return YAMLNode(.sequence(items), line: line)
    }

    mutating func parseFlowMapping() throws(YAMLSyntaxError) -> YAMLNode {
        advance() // {
        var entries: [YAMLEntry] = []
        var seen = Set<String>()
        skipSpaces()
        if peek == "}" { advance(); return YAMLNode(.mapping(entries), line: line) }
        while true {
            skipSpaces()
            let key: String
            if peek == "\"" || peek == "'" { key = try parseQuoted() } else { key = parsePlain(inFlow: true, isKey: true) }
            if key.isEmpty { throw error("empty key in flow mapping") }
            if !seen.insert(key).inserted { throw error("duplicate key '\(key)'") }
            skipSpaces()
            var value = YAMLNode(.scalar("", quoted: false), line: line)
            if peek == ":" {
                advance()
                value = try parseValue(inFlow: true)
            }
            entries.append(YAMLEntry(key: key, keyLine: line, value: value))
            skipSpaces()
            guard let c = peek else { throw error("unterminated '{'") }
            advance()
            if c == "}" { break }
            if c != "," { throw error("expected ',' or '}' in flow mapping") }
            skipSpaces()
            if peek == "}" { advance(); break }
        }
        return YAMLNode(.mapping(entries), line: line)
    }
}
