import Foundation
import KabanProtocol

/// Read failures belong to the inspector, independently of mutation failures.
public enum TaskDetailReadState: Equatable, Sendable {
    case idle, loading, loaded
    case unavailable(CommandError)
}

/// Presentation preserves the daemon's text and open kind namespace.
public enum TaskDetailPresentation {
    public static func normalized(_ source: TaskDetail) -> TaskDetail {
        var value = source
        value.feed = unique(source.feed, id: { $0.id }).sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        value.artifacts = unique(source.artifacts.filter { $0.taskId == source.task.id }, id: { $0.id.rawValue })
            .sorted { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
        value.runs = unique(source.runs.filter { $0.taskId == source.task.id }, id: { $0.id.rawValue })
            .sorted { ($0.startedAt, $0.id.rawValue) < ($1.startedAt, $1.id.rawValue) }
        value.humanRequests = unique(source.humanRequests.filter { $0.taskId == source.task.id }, id: { $0.requestId.rawValue })
        return value
    }
    private static func unique<T>(_ values: [T], id: (T) -> String) -> [T] {
        var result: [T] = [], positions: [String: Int] = [:]
        for value in values {
            let key = id(value)
            if let index = positions[key] { result[index] = value }
            else { positions[key] = result.count; result.append(value) }
        }
        return result
    }
    public static func summaryArtifacts(_ detail: TaskDetail) -> [TaskArtifact] {
        let order = ["summary", "gate_output", "diffstat", "commits", "hook", "issue"]
        return detail.artifacts.sorted {
            let first = order.firstIndex(of: $0.kind) ?? order.count
            let second = order.firstIndex(of: $1.kind) ?? order.count
            return (first, $0.createdAt, $0.id.rawValue) < (second, $1.createdAt, $1.id.rawValue)
        }
    }
    public static func artifactTitle(_ kind: String) -> String {
        switch kind {
        case "summary": "Резюме стадии"
        case "diffstat": "Изменённые файлы"
        case "commits": "Коммиты"
        case "gate_output": "Вывод проверки"
        case "hook": "Вывод hook"
        case "issue": "Замечание"
        case "merge_result": "Результат локального слияния"
        case "merge_conflict": "Конфликт rebase"
        case "merge_gate_output": "Проверка после rebase"
        default: "Материал · " + kind
        }
    }
    public static func feedTitle(_ kind: String) -> String {
        switch kind {
        case "transition": "Переход"
        case "question": "Вопрос"
        case "answer": "Ответ"
        case "review_comment": "Замечание ревью"
        case "merge_conflict": "Конфликт rebase"
        case "merge_gates": "Проверка слияния"
        case "merged": "Локальное слияние завершено"
        case "progress": "Прогресс"
        case "summary": "Резюме"
        case "incident": "Инцидент"
        case "git_denied": "Отказ git"
        case "git_grant": "Разрешение git"
        case "suspicious_files": "Подозрительные файлы"
        default: kind
        }
    }
    /// A material's path is metadata, never a command to read an arbitrary local file.
    public static let largeTextBytes = 64 * 1024
}
