import XCTest
import KabanProtocol
@testable import KabanBoardCore

final class ValidationIssueTextTests: XCTestCase {
    func testInvalidIdentifierUsesTheAcceptedSpecificationWithoutParams() {
        let issue = ValidationIssue(path: "stages[0].id", code: ValidationCode.invalidId, message: "Invalid stage identifier", severity: .error)
        XCTAssertEqual(ValidationIssueText.render(issue), "Id стадии может содержать только строчные латинские буквы, цифры, «-» и «_»; первый символ — буква или цифра, длина до 64")
    }

    func testWholeDocumentTypeMismatchUsesTheRootMessage() {
        let issue = ValidationIssue(path: "", code: ValidationCode.typeMismatch, message: "Expected a mapping", severity: .error)
        XCTAssertEqual(ValidationIssueText.render(issue), "pipeline.yaml должен быть словарём верхнего уровня")
    }

    func testUnknownGitCommandExplainsWhichPartOfTheRuleIsChecked() {
        let issue = ValidationIssue(path: "git.extend[0]", code: ValidationCode.gitUnknownCommand, message: "Unknown git command", severity: .warning, params: ["cmd": "rebsae"])
        XCTAssertEqual(ValidationIssueText.render(issue), "Неизвестная git-команда rebsae (только первое слово правила): проверьте написание")
        XCTAssertEqual(issue.severity, .warning)
    }
    func testAllFortyMessagesMatchSpecificationV0826() {
        let expected = [
            "yaml_syntax": "Ошибка в YAML, строка 7",
            "pipeline_missing": "В базовой ветке нет закоммиченного пайплайна",
            "pipeline_invalid": "Файл пайплайна не в UTF-8 или больше 1 МиБ",
            "version_unsupported": "Версия пайплайна 2 не поддерживается, нужна 1",
            "type_mismatch": "Неверный формат поля stages[1].agent.model",
            "missing_field": "Не заполнено обязательное поле stages[1].agent.model",
            "invalid_value": "Недопустимое значение unexpected в stages[1].agent.model",
            "unknown_key": "Неизвестный ключ future (строка 7), он будет проигнорирован",
            "no_stages": "В пайплайне нет стадий",
            "invalid_id": "Id стадии может содержать только строчные латинские буквы, цифры, «-» и «_»; первый символ — буква или цифра, длина до 64",
            "duplicate_id": "Id «dev» уже занят другой стадией",
            "unknown_stage": "Стадии «dev» нет в пайплайне",
            "queue_count": "Нужна ровно одна стадия Backlog, сейчас 2",
            "merge_count": "Нужна ровно одна стадия Merge, сейчас 2",
            "terminal_missing": "Нет стадии Done",
            "terminal_has_on_success": "Done — последняя стадия, «Дальше» у неё не задаётся",
            "on_success_missing": "Не указано, куда задача идёт после «Разработка 👋»",
            "on_success_cycle": "Стадии идут по кругу: задача никогда не дойдёт до Done",
            "terminal_unreachable": "Из «Разработка 👋» задача не дойдёт до Done",
            "field_not_allowed_for_kind": "Поле wip не используется у стадий типа queue",
            "returns_not_allowed": "Возвраты через returns_to есть только у агентских стадий; у проверки — «Если не прошло», у Merge — «При конфликте»",
            "returns_forward": "Вернуть можно только на более раннюю стадию",
            "no_return_target": "Некуда вернуть: нет стадии, которая правит код",
            "agent_missing": "У стадии «Разработка 👋» не настроен агент",
            "model_missing": "У стадии «Разработка 👋» не выбрана модель",
            "model_auto_forbidden": "Модель auto не подходит: выберите модель явно",
            "harness_unsupported": "Исполнитель custom не поддерживается",
            "wip_out_of_range": "WIP должен быть от 1 до 5",
            "limit_out_of_range": "Лимит задач в ожидании человека должен быть от 1 до 5",
            "attempts_out_of_range": "Число попыток должно быть от 1 до 5",
            "duration_out_of_range": "Лимит задач в ожидании человека должен быть от 1 до 5",
            "backoff_too_long": "Пауз больше, чем попыток: допустимо не больше 5",
            "secret_in_env": "Похоже на секрет в future: не храните секреты в pipeline.yaml",
            "mcp_not_allowlisted": "MCP-сервер «remote» выключен и в запусках будет недоступен",
            "git_hard_invariant": "Это ограничение git отключить нельзя",
            "git_condition_invalid": "Условие other не поддерживается: допустимо только return_reason == <причина>",
            "git_unknown_command": "Неизвестная git-команда rebsae (только первое слово правила): проверьте написание",
            "git_readonly_extend": "Стадия «Разработка 👋» только читает: rebsae разрешить нельзя",
            "git_policy_rule_not_allowed": "В выбранной области правило должно разрешать команду",
            "stage_has_active_tasks": "В «Разработка 👋» есть задачи: сначала перенесите их"
        ]
        XCTAssertEqual(expected.count, 40)
        XCTAssertEqual(ValidationIssueText.knownCodes, Set(expected.keys))
        let publishedConstants = [ValidationCode.modelMissing, ValidationCode.modelAutoForbidden, ValidationCode.mcpNotAllowlisted,
            ValidationCode.backoffTooLong, ValidationCode.stageHasActiveTasks, ValidationCode.terminalUnreachable, ValidationCode.returnsForward,
            ValidationCode.wipOutOfRange, ValidationCode.secretInEnv, ValidationCode.yamlSyntax, ValidationCode.duplicateId,
            ValidationCode.unknownStage, ValidationCode.onSuccessCycle, ValidationCode.gitHardInvariant, ValidationCode.noReturnTarget,
            ValidationCode.typeMismatch, ValidationCode.missingField, ValidationCode.unknownKey, ValidationCode.invalidValue,
            ValidationCode.versionUnsupported, ValidationCode.noStages, ValidationCode.invalidId, ValidationCode.queueCount,
            ValidationCode.mergeCount, ValidationCode.terminalMissing, ValidationCode.onSuccessMissing, ValidationCode.terminalHasOnSuccess,
            ValidationCode.fieldNotAllowedForKind, ValidationCode.returnsNotAllowed, ValidationCode.agentMissing, ValidationCode.harnessUnsupported,
            ValidationCode.limitOutOfRange, ValidationCode.durationOutOfRange, ValidationCode.attemptsOutOfRange, ValidationCode.gitConditionInvalid,
            ValidationCode.gitUnknownCommand, ValidationCode.gitReadonlyExtend]
        XCTAssertEqual(Set(publishedConstants).count, 37)
        XCTAssertTrue(Set(publishedConstants).isSubset(of: ValidationIssueText.knownCodes))
        let params = ["line": "7", "n": "2", "value": "unexpected", "key": "future", "id": "dev", "field": "wip",
                      "kind": "queue", "harness": "custom", "min": "1", "max": "5", "label": "max_waiting_human",
                      "name": "remote", "when": "other", "cmd": "rebsae"]
        for code in expected.keys.sorted() {
            let issue = ValidationIssue(path: "stages[1].agent.model", stageId: code == "no_return_target" ? nil : "dev",
                                        code: code, message: "English fallback", severity: .error, params: params)
            XCTAssertEqual(ValidationIssueText.render(issue, stageName: "Разработка 👋"), expected[code], code)
        }
    }

    func testContextVariantsAndLegacyMessagesKeepTheirMeaning() {
        let duplicate = ValidationIssue(path: "stages[1].returns_to[0].stage", code: ValidationCode.duplicateId,
                                        message: "server", severity: .error, params: ["id": "dev"])
        XCTAssertEqual(ValidationIssueText.render(duplicate), "Возврат в «dev» указан дважды")
        let noTarget = ValidationIssue(path: "stages[1].returns_to[0].stage", stageId: "test", code: ValidationCode.noReturnTarget,
                                       message: "server", severity: .error)
        XCTAssertEqual(ValidationIssueText.render(noTarget), "Вернуть можно только на агентскую стадию, которая правит код")
        let missing = ValidationIssue(path: "stages[1].agent.model", stageId: "dev", code: ValidationCode.modelMissing,
                                      message: "Exact legacy {stage}", severity: .error)
        XCTAssertEqual(ValidationIssueText.render(missing), missing.message)
        let fileLimit = ValidationIssue(path: "suspicious_files.max_file_mb", code: ValidationCode.limitOutOfRange,
                                        message: "Exact file size message", severity: .error, params: ["label": "max_file_mb"])
        XCTAssertEqual(ValidationIssueText.render(fileLimit), fileLimit.message)
        let future = ValidationIssue(path: "", code: "future_code", message: "Exact unknown {path}", severity: .warning)
        XCTAssertEqual(ValidationIssueText.render(future), future.message)
        XCTAssertFalse(ValidationIssueText.knownCodes.contains(future.code))
        XCTAssertEqual(ValidationIssueText.displayPath(future), "pipeline.yaml")
        XCTAssertEqual(ValidationIssueText.displayPath(duplicate), duplicate.path)
    }

    func testEditorLabelsAndDurationsUseServerValues() {
        let issue = ValidationIssue(path: "stages[1].returns_to[0].limit", code: ValidationCode.limitOutOfRange,
                                    message: "server", severity: .error, params: ["label": "returns_to.limit", "min": "2", "max": "9"])
        XCTAssertEqual(ValidationIssueText.render(issue), "Лимит возвратов должен быть от 2 до 9")
        let duration = ValidationIssue(path: "stages[1].timeouts.stall", code: ValidationCode.durationOutOfRange,
                                       message: "server", severity: .error, params: ["label": "stall", "min": "1m", "max": "30m"])
        XCTAssertEqual(ValidationIssueText.render(duration), "Таймаут зависания должен быть от 1 мин до 30 мин")
        var futureLabel = issue; futureLabel.params["label"] = "future_limit"
        XCTAssertEqual(ValidationIssueText.render(futureLabel), "future_limit должен быть от 2 до 9")
    }

}
