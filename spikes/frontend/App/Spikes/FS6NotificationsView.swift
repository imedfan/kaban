import SwiftUI

struct FS6NotificationsView: View {
    @State private var notifier = SpikeNotifier.shared
    @State private var agentResult = ""

    var body: some View {
        SpikeScreen(
            code: "FS-6",
            title: "Уведомления",
            instruments: "Отдельный шаблон не нужен. Для .timeSensitive включите «Не беспокоить» или Focus и смотрите, пробивает ли баннер. Это вопрос Developer ID, не Development-подписи."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Авторизация: \(notifier.auth)")
                Text("Последнее действие: \(notifier.lastAction.isEmpty ? "—" : notifier.lastAction)")
                Text("Текст ответа: \(notifier.lastReply.isEmpty ? "—" : notifier.lastReply)")
                    .font(.title3)
                HStack {
                    Button("Разрешить уведомления") { Task { await notifier.requestAuthorization() } }
                    Button("Вопрос с полем ответа") { notifier.postQuestion() }
                    Button("Инцидент timeSensitive") { notifier.postIncident() }
                }
                HStack {
                    Button("То же из агента: вопрос") { Task { agentResult = await SpikeAgentClient.shared.askAgentToNotify(.question) } }
                    Button("То же из агента: инцидент") { Task { agentResult = await SpikeAgentClient.shared.askAgentToNotify(.incident) } }
                }
                Text(agentResult)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Закройте окно. Приложение остаётся (менюбар и Dock). Повторите вопрос из менюбара и ответьте текстом: строка должна появиться, когда откроете окно снова. Спайк 4 бэкенда — можно ли слать уведомления из агента; сюда пишется дословный результат заглушки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LogList(lines: notifier.log)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
