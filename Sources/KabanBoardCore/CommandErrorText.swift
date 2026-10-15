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
    public static let labels = [
        "bounce_limit_total": "Общий лимит возвратов", "returns_to.limit": "Лимит возвратов",
        "on_fail.limit": "Лимит возвратов при красном гейте", "on_conflict.limit": "Лимит возвратов при конфликте",
        "max_waiting_human": "Лимит задач в ожидании человека", "max_runs_per_task": "Лимит запусков на задачу",
        "max_file_mb": "Максимальный размер файла, МБ", "stall": "Таймаут зависания",
        "wall": "Общий таймаут стадии", "backoff": "Пауза перед повтором"
    ]
    public static func duration(_ value: String) -> String {
        guard let unit = value.last, let name = ["s": "с", "m": "мин", "h": "ч"][String(unit)],
              !value.dropLast().isEmpty, value.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) else { return value }
        return String(value.dropLast()) + " " + name
    }
    public static let knownCodes = Set(templates.keys)
    public static func displayPath(_ issue: ValidationIssue) -> String {
        issue.path.isEmpty ? "pipeline.yaml" : issue.path
    }
    public static func render(_ issue: ValidationIssue, stageName: String? = nil) -> String {
        var issue = issue
        if let label = issue.params["label"] { issue.params["label"] = labels[label] ?? label }
        if issue.code == "duration_out_of_range" {
            for key in ["min", "max"] { if let value = issue.params[key] { issue.params[key] = duration(value) } }
        }
        let template: String
        if issue.code == "type_mismatch", issue.path.isEmpty { template = "pipeline.yaml должен быть словарём верхнего уровня" }
        else if issue.code == "no_return_target" { template = issue.stageId == nil ? "Некуда вернуть: нет стадии, которая правит код" : "Вернуть можно только на агентскую стадию, которая правит код" }
        else if issue.code == "duplicate_id" { template = issue.path.contains("returns_to") ? "Возврат в «{id}» указан дважды" : "Id «{id}» уже занят другой стадией" }
        else if let known = templates[issue.code] { template = known }
        else { return issue.message }
        return render(issue, template: template, stageName: stageName)
    }
    private static let templates: [String: String] = [
        "pipeline_missing": "В базовой ветке нет закоммиченного пайплайна",
        "pipeline_invalid": "Файл пайплайна не в UTF-8 или больше 1 МиБ",
        "git_policy_rule_not_allowed": "В выбранной области правило должно разрешать команду",
        "no_return_target": "Некуда вернуть: нет стадии, которая правит код",
        "duplicate_id": "Id «{id}» уже занят другой стадией",
        "yaml_syntax": "Ошибка в YAML, строка {line}", "version_unsupported": "Версия пайплайна {n} не поддерживается, нужна 1",
        "type_mismatch": "Неверный формат поля {path}", "missing_field": "Не заполнено обязательное поле {path}",
        "invalid_value": "Недопустимое значение {value} в {path}", "unknown_key": "Неизвестный ключ {key} (строка {line}), он будет проигнорирован",
        "no_stages": "В пайплайне нет стадий", "invalid_id": "Id стадии может содержать только строчные латинские буквы, цифры, «-» и «_»; первый символ — буква или цифра, длина до 64",
        "unknown_stage": "Стадии «{id}» нет в пайплайне", "queue_count": "Нужна ровно одна стадия Backlog, сейчас {n}",
        "merge_count": "Нужна ровно одна стадия Merge, сейчас {n}", "terminal_missing": "Нет стадии Done",
        "terminal_has_on_success": "Done — последняя стадия, «Дальше» у неё не задаётся",
        "on_success_missing": "Не указано, куда задача идёт после «{stage}»",
        "on_success_cycle": "Стадии идут по кругу: задача никогда не дойдёт до Done",
        "terminal_unreachable": "Из «{stage}» задача не дойдёт до Done",
        "field_not_allowed_for_kind": "Поле {field} не используется у стадий типа {kind}",
        "returns_not_allowed": "Возвраты через returns_to есть только у агентских стадий; у проверки — «Если не прошло», у Merge — «При конфликте»",
        "returns_forward": "Вернуть можно только на более раннюю стадию",
        "agent_missing": "У стадии «{stage}» не настроен агент", "model_missing": "У стадии «{stage}» не выбрана модель",
        "model_auto_forbidden": "Модель auto не подходит: выберите модель явно", "harness_unsupported": "Исполнитель {harness} не поддерживается",
        "wip_out_of_range": "WIP должен быть от {min} до {max}", "limit_out_of_range": "{label} должен быть от {min} до {max}",
        "attempts_out_of_range": "Число попыток должно быть от {min} до {max}", "duration_out_of_range": "{label} должен быть от {min} до {max}",
        "backoff_too_long": "Пауз больше, чем попыток: допустимо не больше {max}",
        "secret_in_env": "Похоже на секрет в {key}: не храните секреты в pipeline.yaml",
        "mcp_not_allowlisted": "MCP-сервер «{name}» выключен и в запусках будет недоступен",
        "git_hard_invariant": "Это ограничение git отключить нельзя",
        "git_condition_invalid": "Условие {when} не поддерживается: допустимо только return_reason == <причина>",
        "git_unknown_command": "Неизвестная git-команда {cmd} (только первое слово правила): проверьте написание",
        "git_readonly_extend": "Стадия «{stage}» только читает: {cmd} разрешить нельзя",
        "stage_has_active_tasks": "В «{stage}» есть задачи: сначала перенесите их"
    ]
    public static func render(_ issue: ValidationIssue, template: String, stageName: String? = nil) -> String {
        var params = issue.params
        params["path"] = issue.path
        if let stageName {
            params["stage"] = stageName
        }
        return CommandErrorText.fill(template: template, params: params, fallback: issue.message)
    }
}
