import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class SpikeNotifier {
    static let shared = SpikeNotifier()

    static let questionCategory = "spike.question"
    static let incidentCategory = "spike.incident"

    private let bridge = NotificationBridge()
    private(set) var auth = "ещё не запрашивали"
    private(set) var lastReply = ""
    private(set) var lastAction = ""
    private(set) var log: [String] = []

    func install() {
        UNUserNotificationCenter.current().delegate = bridge
        let reply = UNTextInputNotificationAction(
            identifier: "answer",
            title: "Ответить",
            options: [],
            textInputButtonTitle: "Отправить",
            textInputPlaceholder: "Ответ агенту"
        )
        let question = UNNotificationCategory(
            identifier: Self.questionCategory,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        let incident = UNNotificationCategory(
            identifier: Self.incidentCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([question, incident])
        note("категории уведомлений зарегистрированы")
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            auth = granted ? "разрешено" : "отклонено"
            note("авторизация: \(auth)")
        } catch {
            auth = "ошибка"
            note("авторизация: \(error.localizedDescription)")
        }
    }

    func postQuestion() {
        let content = UNMutableNotificationContent()
        content.title = "Вопрос агента"
        content.body = "SHOP-42 ждёт ответ"
        content.categoryIdentifier = Self.questionCategory
        content.threadIdentifier = "spike-shop"
        post(content, label: "question")
    }

    func postIncident() {
        let content = UNMutableNotificationContent()
        content.title = "Инцидент"
        content.body = "refs откатаны"
        content.categoryIdentifier = Self.incidentCategory
        content.threadIdentifier = "spike-shop"
        content.interruptionLevel = .timeSensitive
        post(content, label: "incident.timeSensitive")
    }

    func record(action: String, reply: String?) {
        lastAction = action
        if let reply, !reply.isEmpty {
            lastReply = reply
        }
        note("ответ уведомления action=\(action) text=\(reply ?? "nil")")
    }

    private func post(_ content: UNMutableNotificationContent, label: String) {
        let request = UNNotificationRequest(
            identifier: "\(label)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            let message = error.map { "не доставлено: \($0.localizedDescription)" } ?? "поставлено в центр"
            Task { @MainActor in
                SpikeNotifier.shared.note("\(label): \(message)")
            }
        }
    }

    fileprivate func note(_ message: String) {
        SpikeFileLog.append("fs6", message)
        log.append(message)
        if log.count > 200 {
            log.removeFirst(log.count - 200)
        }
    }
}

private final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        let action = response.actionIdentifier
        await MainActor.run {
            SpikeNotifier.shared.record(action: action, reply: reply)
        }
    }
}
