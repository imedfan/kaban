import Darwin
import Foundation

/// Точечная правка скаляра в подмножестве YAML и заведомо теряющая комментарии перезапись.
/// Подмножество: отступы пробелами, скаляры на той же строке, что ключ, блоки `|` / `>`,
/// списки вида `- key: value`. Якоря, flow-коллекции и многострочные ключи не поддерживаются.
enum PipelineYamlEditor {
    enum Component: Equatable, CustomStringConvertible {
        case key(String)
        case index(Int)

        var description: String {
            switch self {
            case .key(let key):
                return key
            case .index(let index):
                return "[\(index)]"
            }
        }
    }

    enum EditError: Error, Equatable, CustomStringConvertible {
        case pathNotFound(String)
        case notScalar(String)
        case valueRejected(String)

        var description: String {
            switch self {
            case .pathNotFound(let path):
                return "путь не найден: \(path)"
            case .notScalar(let path):
                return "по пути не скаляр: \(path)"
            case .valueRejected(let reason):
                return "значение отклонено: \(reason)"
            }
        }
    }

    struct Report: Equatable {
        var surgical: String
        var naive: String
        var failures: [String]
    }

    static func pathDescription(_ path: [Component]) -> String {
        path.map(\.description).joined(separator: ".")
    }

    /// Меняет один скаляр, сохраняя комментарии, отступы и порядок строк.
    static func surgicalReplace(in source: String, path: [Component], newValue: String) throws -> String {
        try validate(newValue)
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let trailingNewline = normalized.hasSuffix("\n")
        var lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var replaced = false
        try walk(lines) { index, linePath, isScalar in
            guard linePath == path else { return }
            if !isScalar {
                throw EditError.notScalar(pathDescription(path))
            }
            lines[index] = try replaceScalar(on: lines[index], newValue: newValue)
            replaced = true
        }
        if !replaced {
            throw EditError.pathNotFound(pathDescription(path))
        }
        var text = lines.joined(separator: "\n")
        if trailingNewline && !text.hasSuffix("\n") {
            text.append("\n")
        }
        return text
    }

    /// Стенд вместо Yams: комментарии выбрасываются, ключи сортируются.
    static func naiveRewrite(in source: String, replacements: [([Component], String)]) -> String {
        var scalars: [(path: [Component], value: String)] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        walkCollecting(lines: lines, into: &scalars)
        for (path, newValue) in replacements {
            guard let index = scalars.firstIndex(where: { $0.path == path }) else { continue }
            scalars[index].value = newValue
        }
        let sorted = scalars.sorted { pathDescription($0.path) < pathDescription($1.path) }
        var output = "# naive rewrite: комментарии удалены, ключи отсортированы\n"
        for item in sorted {
            output += "\(pathDescription(item.path)): \(renderScalar(item.value))\n"
        }
        return output
    }

    static func applyFixtureEdits(to source: String) throws -> Report {
        let runs: [Component] = [.key("board"), .key("max_runs_per_task")]
        let model: [Component] = [.key("stages"), .index(1), .key("model")]
        let surgicalRuns = try surgicalReplace(in: source, path: runs, newValue: "13")
        let surgical = try surgicalReplace(in: surgicalRuns, path: model, newValue: "opus-4.5")
        let naive = naiveRewrite(in: source, replacements: [(runs, "13"), (model, "opus-4.5")])
        return Report(surgical: surgical, naive: naive, failures: invariantFailures(original: source, surgical: surgical, naive: naive))
    }

    static func invariantFailures(original: String, surgical: String, naive: String) -> [String] {
        var failures: [String] = []
        let originalLines = lines(of: original)
        let surgicalLines = lines(of: surgical)
        if originalLines.count != surgicalLines.count {
            failures.append("число строк изменилось: \(originalLines.count) → \(surgicalLines.count)")
        }
        let count = min(originalLines.count, surgicalLines.count)
        for index in 0..<count {
            let before = originalLines[index]
            let after = surgicalLines[index]
            if isCommentLine(before) && before != after {
                failures.append("комментарий изменён, строка \(index + 1): \(before)")
            }
        }
        if !surgical.contains("max_runs_per_task: 13 # не трогать этот комментарий") {
            failures.append("не сохранена строка max_runs_per_task с комментарием")
        }
        if !surgical.contains("model: opus-4.5") {
            failures.append("модель Dev не заменена на opus-4.5")
        }
        if surgical.contains("model: composer-2") {
            failures.append("старое значение model: composer-2 осталось")
        }
        if !surgical.contains("Многострочный блок.") || !surgical.contains("Внутри слово composer-2 и число 12.") {
            failures.append("блок | повреждён")
        }
        if !surgical.contains("# Число 12 в этом комментарии не является значением max_runs_per_task.") {
            failures.append("комментарий с числом 12 потерян")
        }
        let originalKeys = topLevelKeys(in: original)
        let surgicalKeys = topLevelKeys(in: surgical)
        if originalKeys != surgicalKeys {
            failures.append("порядок ключей верхнего уровня: \(originalKeys) → \(surgicalKeys)")
        }
        if naive.contains("# pipeline.yaml") || naive.contains("не трогать этот комментарий") {
            failures.append("наивная перезапись сохранила комментарий — стенд сломан")
        }
        if !naive.contains("[1].model: opus-4.5") && !naive.contains("[1].model: \"opus-4.5\"") {
            failures.append("наивная перезапись не содержит новую модель")
        }
        return failures
    }

    static func selfCheck(source: String) -> [String] {
        do {
            let report = try applyFixtureEdits(to: source)
            return report.failures
        } catch {
            return ["правка бросила ошибку: \(error)"]
        }
    }

    // MARK: - Walk

    private struct Frame {
        var indent: Int
        var component: Component
        var nextIndex: Int
    }

    private static func walk(
        _ lines: [String],
        body: (_ index: Int, _ path: [Component], _ isScalar: Bool) throws -> Void
    ) throws {
        var stack: [Frame] = []
        var blockFloor: Int?
        for index in lines.indices {
            let line = lines[index]
            if let floor = blockFloor {
                if line.trimmingCharacters(in: .whitespaces).isEmpty || indent(of: line) > floor {
                    continue
                }
                blockFloor = nil
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                let markerIndent = indent(of: line)
                pop(&stack, indentAtLeast: markerIndent)
                guard var parent = stack.popLast() else { continue }
                let itemIndex = parent.nextIndex
                parent.nextIndex += 1
                stack.append(parent)
                stack.append(Frame(indent: markerIndent, component: .index(itemIndex), nextIndex: 0))
                let content = String(trimmed.dropFirst(2))
                if content.isEmpty {
                    continue
                }
                if let parsed = parseKey(content) {
                    let keyIndent = markerIndent + 2
                    let path = stack.map(\.component) + [.key(parsed.key)]
                    let scalar = classifyScalar(parsed.rest)
                    try body(index, path, scalar)
                    stack.append(Frame(indent: keyIndent, component: .key(parsed.key), nextIndex: 0))
                    if isBlockScalar(parsed.rest) {
                        blockFloor = keyIndent
                    }
                }
                continue
            }
            guard let parsed = parseKey(trimmed) else { continue }
            let keyIndent = indent(of: line)
            pop(&stack, indentAtLeast: keyIndent)
            let path = stack.map(\.component) + [.key(parsed.key)]
            let scalar = classifyScalar(parsed.rest)
            try body(index, path, scalar)
            stack.append(Frame(indent: keyIndent, component: .key(parsed.key), nextIndex: 0))
            if isBlockScalar(parsed.rest) {
                blockFloor = keyIndent
            }
        }
    }

    private static func walkCollecting(lines: [String], into scalars: inout [(path: [Component], value: String)]) {
        try? walk(lines) { index, path, isScalar in
            guard isScalar, let value = scalarValue(on: lines[index]) else { return }
            scalars.append((path, value))
        }
    }

    private static func pop(_ stack: inout [Frame], indentAtLeast indent: Int) {
        while let top = stack.last, top.indent >= indent {
            stack.removeLast()
        }
    }

    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func parseKey(_ content: String) -> (key: String, rest: String)? {
        guard let colon = content.firstIndex(of: ":") else { return nil }
        let key = String(content[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        let rest = String(content[content.index(after: colon)...])
        return (key, rest)
    }

    private static func classifyScalar(_ rest: String) -> Bool {
        scalarValue(fromRest: rest) != nil
    }

    private static func isBlockScalar(_ rest: String) -> Bool {
        let token = rest.trimmingCharacters(in: .whitespaces)
        return token == "|" || token == ">" || token.hasPrefix("|-") || token.hasPrefix(">+")
            || token.hasPrefix("|+") || token.hasPrefix(">-")
    }

    private static func scalarValue(on line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let content = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
        guard let parsed = parseKey(content) else { return nil }
        return scalarValue(fromRest: parsed.rest)
    }

    private static func scalarValue(fromRest rest: String) -> String? {
        if isBlockScalar(rest) {
            return nil
        }
        guard let split = splitComment(rest) else { return nil }
        if split.value.isEmpty {
            return nil
        }
        return split.value
    }

    private static func splitComment(_ rest: String) -> (value: String, comment: String)? {
        var inSingle = false
        var inDouble = false
        let chars = Array(rest)
        for index in chars.indices {
            let character = chars[index]
            if character == "'" && !inDouble {
                inSingle.toggle()
            } else if character == "\"" && !inSingle {
                inDouble.toggle()
            } else if character == "#" && !inSingle && !inDouble {
                let value = String(chars[..<index]).trimmingCharacters(in: .whitespaces)
                let hadSpace = index > chars.startIndex && chars[chars.index(before: index)] == " "
                let comment = (hadSpace ? " " : "") + String(chars[index...])
                return (value, comment)
            }
        }
        let value = rest.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || isBlockScalar(rest) {
            return nil
        }
        return (value, "")
    }

    private static func replaceScalar(on line: String, newValue: String) throws -> String {
        let leading = String(line.prefix(while: { $0 == " " }))
        let trimmed = String(line.drop(while: { $0 == " " }))
        let listPrefix: String
        let content: String
        if trimmed.hasPrefix("- ") {
            listPrefix = "- "
            content = String(trimmed.dropFirst(2))
        } else {
            listPrefix = ""
            content = trimmed
        }
        guard let parsed = parseKey(content), let split = splitComment(parsed.rest), !split.value.isEmpty else {
            throw EditError.notScalar(line)
        }
        return "\(leading)\(listPrefix)\(parsed.key): \(renderScalar(newValue))\(split.comment)"
    }

    private static func renderScalar(_ value: String) -> String {
        if value.isEmpty || value.contains(" ") || value.contains(":") || value.contains("#") {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func validate(_ value: String) throws {
        if value.contains("\n") || value.contains("\r") {
            throw EditError.valueRejected("перевод строки")
        }
    }

    private static func lines(of source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    private static func isCommentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#")
    }

    private static func topLevelKeys(in source: String) -> [String] {
        lines(of: source).compactMap { line in
            guard indent(of: line) == 0 else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return parseKey(trimmed)?.key
        }
    }
}

#if SPIKE_YAML_MAIN
@main
struct YamlSelfCheckMain {
    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/pipeline.yaml"
        let url = URL(fileURLWithPath: path)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("не удалось прочитать \(path)\n", stderr)
            exit(2)
        }
        let failures = PipelineYamlEditor.selfCheck(source: source)
        if failures.isEmpty {
            print("yaml self-check ok")
            exit(0)
        }
        for failure in failures {
            fputs(failure + "\n", stderr)
        }
        exit(1)
    }
}
#endif
