import XCTest
@testable import KabanBoardCore
import KabanProtocol

final class IdentityDraftTests: XCTestCase {
    func testFirstRefusalFillsFoundValuesAndDoesNotHighlight() {
        let bothMissing = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["missing": "name,email"]
        )
        let empty = IdentityDraft().refusing(bothMissing, submitted: nil)
        XCTAssertEqual(empty.generalMessage, IdentityDraft.generalText)
        XCTAssertEqual(empty.name.value, "")
        XCTAssertEqual(empty.email.value, "")
        XCTAssertFalse(empty.name.highlighted)
        XCTAssertFalse(empty.email.highlighted)
        XCTAssertNil(empty.clarification)
        XCTAssertEqual(empty.focus, .name)

        let onlyName = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["missing": "email", "name": "Repo User"]
        )
        let named = IdentityDraft().refusing(onlyName, submitted: nil)
        XCTAssertEqual(named.name.value, "Repo User")
        XCTAssertTrue(named.name.fromGitSettings)
        XCTAssertFalse(named.name.highlighted)
        XCTAssertEqual(named.email.value, "")
        XCTAssertFalse(named.email.highlighted)
        XCTAssertEqual(named.clarification, "В настройках git нашлось только имя, почты нет")
        XCTAssertEqual(named.focus, .email)

        let onlyEmail = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["missing": "name", "email": "a@b"]
        )
        let mailed = IdentityDraft().refusing(onlyEmail, submitted: nil)
        XCTAssertEqual(mailed.clarification, "В настройках git нашлась только почта, имени нет")
        XCTAssertEqual(mailed.email.value, "a@b")
        XCTAssertTrue(mailed.email.fromGitSettings)
        XCTAssertEqual(mailed.focus, .name)
    }

    func testFirstRefusalInvalidHasCaptionWithoutHighlightOrClarification() {
        let invalidEmail = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["invalid": "email", "name": "Repo Local"]
        )
        let draft = IdentityDraft().refusing(invalidEmail, submitted: nil)
        XCTAssertEqual(draft.name.value, "Repo Local")
        XCTAssertTrue(draft.name.fromGitSettings)
        XCTAssertEqual(draft.email.value, "")
        XCTAssertFalse(draft.email.highlighted)
        XCTAssertEqual(draft.email.caption, "Почта в настройках git содержит служебные символы, укажите вручную")
        XCTAssertNil(draft.clarification)
        XCTAssertEqual(draft.focus, .email)

        let invalidName = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["invalid": "name", "missing": "email"]
        )
        let both = IdentityDraft().refusing(invalidName, submitted: nil)
        XCTAssertNil(both.clarification)
        XCTAssertEqual(both.name.value, "")
        XCTAssertEqual(both.email.value, "")
        XCTAssertFalse(both.name.highlighted)
        XCTAssertFalse(both.email.highlighted)
        XCTAssertEqual(both.name.caption, "Имя в настройках git содержит служебные символы, укажите вручную")
        XCTAssertNil(both.email.caption)
        XCTAssertEqual(both.focus, .name)
    }

    func testEnteredIdentityStaysAfterRefusal() {
        var draft = IdentityDraft()
        let first = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["missing": "email", "name": "Repo User"]
        )
        draft = draft.refusing(first, submitted: nil)
        draft.name.value = "Artem"
        draft.email.value = "bad\nmail"

        let refused = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["invalid": "email", "name": "Artem"]
        )
        let kept = draft.refusing(refused, submitted: GitIdentity(name: "Artem", email: "bad\nmail"))
        XCTAssertEqual(kept.name.value, "Artem")
        XCTAssertEqual(kept.email.value, "bad\nmail")
        XCTAssertFalse(kept.name.fromGitSettings)
        XCTAssertFalse(kept.email.fromGitSettings)
        XCTAssertFalse(kept.name.highlighted)
        XCTAssertNil(kept.name.caption)
        XCTAssertTrue(kept.email.highlighted)
        XCTAssertEqual(kept.email.caption, "Почта должна быть в одну строку, без служебных символов")
        XCTAssertNil(kept.clarification)
        XCTAssertEqual(kept.focus, .email)
        XCTAssertEqual(kept.enteredIdentity, GitIdentity(name: "Artem", email: "bad\nmail"))

        let missingEmail = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["missing": "email", "name": "Artem"]
        )
        let blankEmail = IdentityDraft(name: "Artem", email: "").refusing(
            missingEmail, submitted: GitIdentity(name: "Artem", email: "")
        )
        XCTAssertEqual(blankEmail.name.value, "Artem")
        XCTAssertEqual(blankEmail.email.value, "")
        XCTAssertFalse(blankEmail.name.highlighted)
        XCTAssertTrue(blankEmail.email.highlighted)
        XCTAssertEqual(blankEmail.email.caption, "Укажите почту")
        XCTAssertEqual(blankEmail.focus, .email)

        let both = CommandError(
            code: CommandError.identityRequiredCode,
            message: "служебное",
            params: ["missing": "name,email"]
        )
        let cleared = IdentityDraft(name: " ", email: " ").refusing(both, submitted: GitIdentity(name: " ", email: " "))
        XCTAssertEqual(cleared.name.value, " ")
        XCTAssertEqual(cleared.email.value, " ")
        XCTAssertTrue(cleared.name.highlighted)
        XCTAssertTrue(cleared.email.highlighted)
        XCTAssertEqual(cleared.name.caption, "Укажите имя")
        XCTAssertEqual(cleared.email.caption, "Укажите почту")
        XCTAssertEqual(cleared.focus, .name)
    }

    func testEmptyParamsKeepEnteredValuesAndShowOnlyTheGeneralText() {
        let error = CommandError(code: CommandError.identityRequiredCode, message: "от демона", params: [:])
        let first = IdentityDraft().refusing(error, submitted: nil)
        XCTAssertEqual(first.generalMessage, IdentityDraft.generalText)
        XCTAssertEqual(first.name.value, "")
        XCTAssertEqual(first.email.value, "")
        XCTAssertFalse(first.name.highlighted)
        XCTAssertFalse(first.email.highlighted)
        XCTAssertNil(first.focus)
        XCTAssertNil(first.clarification)

        let typed = IdentityDraft(identity: GitIdentity(name: "Artem", email: "a@b.c"))
        let again = typed.refusing(error, submitted: typed.enteredIdentity)
        XCTAssertEqual(again.name.value, "Artem")
        XCTAssertEqual(again.email.value, "a@b.c")
        XCTAssertFalse(again.name.highlighted)
        XCTAssertFalse(again.email.highlighted)
        XCTAssertNil(again.name.caption)
        XCTAssertNil(again.focus)
        XCTAssertEqual(again.generalMessage, IdentityDraft.generalText)
    }

    func testSettingsDraftStartsFromProjectIdentity() {
        let draft = IdentityDraft(identity: GitIdentity(name: "Artem Palkin", email: "artem@example.com"))
        XCTAssertEqual(draft.name.value, "Artem Palkin")
        XCTAssertEqual(draft.email.value, "artem@example.com")
        XCTAssertEqual(IdentityDraft(identity: nil).name.value, "")
    }
}

final class CommandErrorTextTests: XCTestCase {
    func testParamsFillPlaceholdersAndMissingKeyFallsBackToMessage() {
        let filled = CommandError(
            code: CommandError.identityRequiredCode,
            message: "Нет поля {missing}",
            params: ["missing": "email", "name": "Artem"]
        )
        XCTAssertEqual(CommandErrorText.render(filled), "Нет поля email")

        let bare = CommandError(code: CommandError.identityRequiredCode, message: "Нет поля {missing}", params: [:])
        XCTAssertEqual(CommandErrorText.render(bare), "Нет поля {missing}")

        let other = CommandError(code: "custom", message: "запасной текст", params: ["name": "Artem"])
        XCTAssertEqual(CommandErrorText.render(other, template: "Автор {name}, нет {email}"), "запасной текст")
        XCTAssertEqual(CommandErrorText.render(other, template: "Автор {name}"), "Автор Artem")
        XCTAssertEqual(CommandErrorText.render(other), "запасной текст")
    }

    func testValidationIssueUsesParamsAndFallsBackToMessage() {
        let issue = ValidationIssue(
            path: "stages[1].git.extend[0]",
            stageId: "dev",
            code: ValidationCode.gitReadonlyExtend,
            message: "Стадия только читает",
            severity: .error,
            params: ["cmd": "reset"]
        )
        let template = "Стадия «{stage}» только читает: `{cmd}` разрешить нельзя"
        XCTAssertEqual(ValidationIssueText.render(issue, template: template), issue.message)
        XCTAssertEqual(
            ValidationIssueText.render(issue, template: template, stageName: "Dev"),
            "Стадия «Dev» только читает: `reset` разрешить нельзя"
        )
        let withoutParams = ValidationIssue(
            path: "stages[1].wip", code: ValidationCode.wipOutOfRange, message: "как прислал демон", severity: .error
        )
        XCTAssertEqual(
            ValidationIssueText.render(withoutParams, template: "WIP от {min} до {max}", stageName: "Dev"),
            "как прислал демон"
        )
    }
}
