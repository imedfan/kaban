import Foundation
import KabanProtocol

/// Подстановка `{ключ}` из `params`. Если хотя бы одного ключа в словаре нет,
/// возвращается `fallback` целиком — обычно готовый `message` демона.
public enum CommandErrorText {
    public static func render(_ error: CommandError, template: String? = nil) -> String {
        fill(template: template ?? error.message, params: error.params, fallback: error.message)
    }

    public static func fill(template: String, params: [String: String], fallback: String) -> String {
        let pieces = pieces(in: template)
        let keys = pieces.compactMap(\.key)
        guard keys.allSatisfy({ params[$0] != nil }) else { return fallback }
        return pieces.map { piece in
            if let key = piece.key { return params[key] ?? "" }
            return piece.text
        }.joined()
    }

    private struct Piece {
        var text: String
        var key: String?
    }

    private static func pieces(in template: String) -> [Piece] {
        var result: [Piece] = []
        var cursor = template.startIndex
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let close = template[template.index(after: index)...].firstIndex(of: "}"),
               template.index(after: index) < close {
                let key = String(template[template.index(after: index)..<close])
                if isPlaceholderKey(key) {
                    if cursor < index {
                        result.append(Piece(text: String(template[cursor..<index]), key: nil))
                    }
                    result.append(Piece(text: "", key: key))
                    index = template.index(after: close)
                    cursor = index
                    continue
                }
            }
            index = template.index(after: index)
        }
        if cursor < template.endIndex {
            result.append(Piece(text: String(template[cursor...]), key: nil))
        }
        return result
    }

    private static func isPlaceholderKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII && (first.isLetter || first == "_") else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

/// Текст `ValidationIssue`: `{path}` берётся из issue, `{stage}` — имя, которое передал вызывающий
/// (клиент его не вычисляет из YAML), остальные ключи — из `params`. Не хватает ключа — `message`.
public enum ValidationIssueText {
    public static func render(_ issue: ValidationIssue, template: String, stageName: String? = nil) -> String {
        var params = issue.params
        params["path"] = issue.path
        if let stageName {
            params["stage"] = stageName
        }
        return CommandErrorText.fill(template: template, params: params, fallback: issue.message)
    }
}
