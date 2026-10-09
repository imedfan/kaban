import Foundation
import Observation
import UserNotifications
import KabanBoardCore
import KabanProtocol

@MainActor @Observable final class NativeNotifications: NSObject, UNUserNotificationCenterDelegate {
    struct Inbox: Codable {
        let id: UUID
        let source: String
        let target: AttentionTarget
        let reply: String?
        var attempted: Bool
    }
    private weak var runtime: DaemonRuntime?
    private weak var store: BoardStore?
    private let storage: any KeyValueStoring
    private let inboxKey = "client.notification.inbox"
    private var attachment = UUID()
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var routing: Task<Void, Never>?
    private var routingID = UUID()
    private(set) var inbox: Inbox?
    private(set) var message: String?
    override init() {
        storage = BoardQA.isActive ? MemoryKeyValueStore() : DefaultsStorage()
        super.init()
        do { inbox = try storage.data(forKey: inboxKey).map { try KabanCoding.makeDecoder().decode(Inbox.self, from: $0) } }
        catch { message = "Не удалось прочитать сохранённый ответ из уведомления." }
    }
    func configure(_ runtime: DaemonRuntime) {
        self.runtime = runtime
        guard !BoardQA.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "kaban.reply", title: "Ответить", options: [.foreground], textInputButtonTitle: "Отправить", textInputPlaceholder: "Ответ на вопрос")
        center.setNotificationCategories([UNNotificationCategory(identifier: "kaban.question", actions: [reply], intentIdentifiers: [], options: [])])
    }
    func attach(_ store: BoardStore) {
        detach(); self.store = store
        store.session.onAppliedUpdate = { [weak self, weak store] update in
            guard let self, let store, let board = store.projection else { return }
            for notice in store.attention.receive(update, board: board, now: Date()) { self.deliver(notice, store: store) }
            if case .ready = update { self.processInbox() }
        }
    }
    func detach() {
        store?.session.onAppliedUpdate = nil
        attachment = UUID(); store = nil
        for task in deliveries.values { task.cancel() }; deliveries = [:]
        routingID = UUID(); routing?.cancel(); routing = nil
    }
    func setEnabled(_ value: Bool) { store?.attention.setEnabled(value) }
    private func deliver(_ notice: AttentionNotice, store: BoardStore) {
        guard !BoardQA.isActive, !store.usesFixture else { return }
        let token = attachment, id = UUID(), source = store.sourceKey
        deliveries[id] = Task { [weak self, weak store] in
            defer { self?.deliveries[id] = nil }
            let center = UNUserNotificationCenter.current()
            let permission = await center.notificationSettings().authorizationStatus
            guard !Task.isCancelled, let self, let store, self.attachment == token,
                  store.attention.enabled, [.authorized, .provisional].contains(permission) else { return }
            do {
                let content = UNMutableNotificationContent()
                content.title = notice.title; content.body = notice.body; content.sound = .default
                if notice.timeSensitive { content.interruptionLevel = .timeSensitive }
                if notice.canReply { content.categoryIdentifier = "kaban.question" }
                switch notice.target {
                case .task(let project, _, _), .incident(let project, _, _): content.threadIdentifier = project.rawValue
                case .board: content.threadIdentifier = "kaban.global"
                }
                content.userInfo = ["kaban.target": try KabanCoding.makeEncoder().encode(notice.target), "kaban.source": source]
                try await center.add(UNNotificationRequest(identifier: "kaban." + notice.id, content: content, trigger: nil))
            } catch {
                if self.attachment == token { self.message = "Не удалось доставить уведомление. Состояние доступно в Kaban." }
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let data = response.notification.request.content.userInfo["kaban.target"] as? Data
        let source = response.notification.request.content.userInfo["kaban.source"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard let data, let source, let target = try? KabanCoding.makeDecoder().decode(AttentionTarget.self, from: data) else {
                self.message = "Уведомление не содержит актуального адреса задачи."; return
            }
            self.receive(target: target, source: source, reply: text)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let enabled = await MainActor.run { self.store?.attention.enabled == true }
        return enabled ? [.banner, .sound] : []
    }
    func receive(target: AttentionTarget, source: String, reply: String?) {
        routingID = UUID(); routing?.cancel(); routing = nil
        inbox = .init(id: UUID(), source: source, target: target, reply: reply, attempted: false)
        persistInbox(); runtime?.presentBoard?(); processInbox()
    }
    func dismissInbox() { guard routing == nil else { return }; inbox = nil; message = nil; persistInbox() }
    func retryInbox() { guard routing == nil else { return }; inbox?.attempted = false; persistInbox(); processInbox() }
    private func processInbox() {
        guard routing == nil, let pending = inbox, !pending.attempted, let store,
              store.canSend, runtime?.presentBoard != nil else { return }
        guard pending.source == store.sourceKey else { message = "Уведомление относится к другому источнику Kaban. Ответ сохранён и не отправлен."; return }
        inbox?.attempted = true; persistInbox()
        let token = attachment, worker = UUID(); routingID = worker
        routing = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer {
                if self.routingID == worker {
                    self.routing = nil
                    if self.attachment == token, self.inbox?.id == pending.id, let message = self.message { store.error = message }
                }
            }
            self.message = nil
            self.runtime?.presentBoard?()
            store.screen = .board
            switch pending.target {
            case .board: self.message = nil
            case .task(let project, let task, let request):
                guard store.projection?.tasks[task]?.projectId == project else { self.message = "Задача или проект удалены. Ответ не отправлен."; return }
                store.focusProject(project); await store.select(task)
                guard !Task.isCancelled, self.attachment == token, self.inbox?.id == pending.id else { return }
                if let text = pending.reply {
                    guard let request else { self.message = "Это уведомление не относится к вопросу. Ответ не отправлен."; return }
                    if let error = store.humanAnswers.prepareNotificationReply(text, for: task, requestID: request) { self.message = error; return }
                    let sent = await store.humanAnswers.submit(task)
                    guard !Task.isCancelled, self.attachment == token, self.inbox?.id == pending.id else { return }
                    if !sent { self.message = "Ответ сохранён. Проверьте отказ или подтверждение в панели задачи."; return }
                } else if let request, store.session.detail?.humanRequests.last?.requestId != request {
                    self.message = "Вопрос изменился. Открыта актуальная задача."; return
                }
                self.message = nil
            case .incident(let project, let task, let incident):
                guard store.projection?.projects[project] != nil else { self.message = "Проект удалён. История инцидентов доступна в Kaban."; store.screen = .incidents; return }
                store.focusProject(project); store.screen = .incidents
                await store.incidents.refresh()
                guard !Task.isCancelled, self.attachment == token, self.inbox?.id == pending.id else { return }
                store.incidents.selectedID = incident
                if store.projection?.tasks[task] != nil { await store.select(task) }
                if store.incidents.selected == nil { self.message = "Инцидент больше недоступен. Обновите историю."; return }
            }
            if self.inbox?.id == pending.id { self.inbox = nil; self.persistInbox() }
        }
    }
    private func persistInbox() {
        do { storage.set(try inbox.map { try KabanCoding.makeEncoder().encode($0) }, forKey: inboxKey) }
        catch { message = "Не удалось сохранить ответ из уведомления. Ответ не отправлен." }
    }
}
