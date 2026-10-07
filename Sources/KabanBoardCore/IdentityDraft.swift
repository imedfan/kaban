import Foundation
import KabanProtocol

public enum IdentityField: String, Codable, Equatable, Sendable {
    case name
    case email
}

/// Поле «Имя» или «Почта» в листе «Добавить проект» и в строке «Автор коммитов».
public struct IdentityFieldDraft: Codable, Equatable, Sendable {
    public var value: String
    /// Значение подставлено из `params` первого отказа, пометка «из настроек git».
    public var fromGitSettings: Bool
    public var highlighted: Bool
    public var caption: String?

    public init(value: String = "", fromGitSettings: Bool = false, highlighted: Bool = false, caption: String? = nil) {
        self.value = value
        self.fromGitSettings = fromGitSettings
        self.highlighted = highlighted
        self.caption = caption
    }
}

/// Черновик автора коммитов. Пустоту, пробелы и служебные символы проверяет демон;
/// после отказа вызову с `identity` в полях остаётся то, что ввёл пользователь.
public struct IdentityDraft: Codable, Equatable, Sendable {
    public static let generalText = "Не задан автор коммитов: укажите имя и почту"

    public var name: IdentityFieldDraft
    public var email: IdentityFieldDraft
    public var generalMessage: String?
    /// Уточнение только у первого отказа, и только когда второе поле в `missing`.
    public var clarification: String?
    public var focus: IdentityField?

    public init(name: String = "", email: String = "") {
        self.name = IdentityFieldDraft(value: name)
        self.email = IdentityFieldDraft(value: email)
        generalMessage = nil
        clarification = nil
        focus = nil
    }

    /// Поля «Изменить…» из `ProjectSummary.identity`. `nil` у старого демона — пустые поля.
    public init(identity: GitIdentity?) {
        self.init(name: identity?.name ?? "", email: identity?.email ?? "")
    }

    public var enteredIdentity: GitIdentity {
        GitIdentity(name: name.value, email: email.value)
    }

    /// `submitted == nil` — вызов без `identity` (первый отказ). Иначе отказ вызову,
    /// который уже нёс введённые имя и почту: эти строки не затираются.
    public func refusing(_ error: CommandError, submitted: GitIdentity?) -> IdentityDraft {
        var draft = self
        draft.clarification = nil
        draft.focus = nil
        draft.name.highlighted = false
        draft.name.caption = nil
        draft.name.fromGitSettings = false
        draft.email.highlighted = false
        draft.email.caption = nil
        draft.email.fromGitSettings = false

        guard error.code == CommandError.identityRequiredCode else {
            draft.generalMessage = CommandErrorText.render(error)
            return draft
        }
        draft.generalMessage = Self.generalText

        let missing = Self.fields(error.params["missing"])
        let invalid = Self.fields(error.params["invalid"])
        if submitted == nil {
            draft.name = Self.firstRefusal(.name, missing: missing, invalid: invalid, params: error.params)
            draft.email = Self.firstRefusal(.email, missing: missing, invalid: invalid, params: error.params)
            draft.clarification = Self.clarification(missing: missing, invalid: invalid, params: error.params)
        } else {
            Self.markSubmitted(&draft.name, field: .name, missing: missing, invalid: invalid)
            Self.markSubmitted(&draft.email, field: .email, missing: missing, invalid: invalid)
        }
        if !error.params.isEmpty {
            draft.focus = [.name, .email].first { missing.contains($0) || invalid.contains($0) }
        }
        return draft
    }

    private static func fields(_ raw: String?) -> Set<IdentityField> {
        guard let raw else { return [] }
        let tokens = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return Set([IdentityField.name, .email].filter { tokens.contains($0.rawValue) })
    }

    private static func firstRefusal(
        _ field: IdentityField,
        missing: Set<IdentityField>,
        invalid: Set<IdentityField>,
        params: [String: String]
    ) -> IdentityFieldDraft {
        if invalid.contains(field) {
            return IdentityFieldDraft(value: "", caption: gitInvalidCaption(field))
        }
        if missing.contains(field) {
            return IdentityFieldDraft(value: "")
        }
        if let found = params[field.rawValue] {
            return IdentityFieldDraft(value: found, fromGitSettings: true)
        }
        return IdentityFieldDraft(value: "")
    }

    private static func markSubmitted(
        _ field: inout IdentityFieldDraft,
        field kind: IdentityField,
        missing: Set<IdentityField>,
        invalid: Set<IdentityField>
    ) {
        if invalid.contains(kind) {
            field.highlighted = true
            field.caption = submittedInvalidCaption(kind)
        } else if missing.contains(kind) {
            field.highlighted = true
            field.caption = submittedMissingCaption(kind)
        }
    }

    /// Уточнение есть, только когда нашлось ровно одно поле, а второе лежит в `missing`.
    private static func clarification(missing: Set<IdentityField>, invalid: Set<IdentityField>, params: [String: String]) -> String? {
        let nameFound = params["name"] != nil && !missing.contains(.name) && !invalid.contains(.name)
        let emailFound = params["email"] != nil && !missing.contains(.email) && !invalid.contains(.email)
        if nameFound && missing.contains(.email) && !invalid.contains(.email) && !emailFound {
            return "В настройках git нашлось только имя, почты нет"
        }
        if emailFound && missing.contains(.name) && !invalid.contains(.name) && !nameFound {
            return "В настройках git нашлась только почта, имени нет"
        }
        return nil
    }

    private static func gitInvalidCaption(_ field: IdentityField) -> String {
        switch field {
        case .name: "Имя в настройках git содержит служебные символы, укажите вручную"
        case .email: "Почта в настройках git содержит служебные символы, укажите вручную"
        }
    }

    private static func submittedMissingCaption(_ field: IdentityField) -> String {
        switch field {
        case .name: "Укажите имя"
        case .email: "Укажите почту"
        }
    }

    private static func submittedInvalidCaption(_ field: IdentityField) -> String {
        switch field {
        case .name: "Имя должно быть в одну строку, без служебных символов"
        case .email: "Почта должна быть в одну строку, без служебных символов"
        }
    }
}
