import SwiftUI

struct FS7LoginItemsView: View {
    @State private var client = SpikeAgentClient.shared

    var body: some View {
        SpikeScreen(
            code: "FS-7",
            title: "Одобрение в Объектах входа",
            instruments: "Смотрите System Settings → General → Login Items и журнал статусов. Снимайте скриншот каждого диалога."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Путь бандла", value: client.bundlePath)
                LabeledContent("Версия", value: client.bundleVersion)
                LabeledContent("Team ID", value: client.teamID)
                LabeledContent("SMAppService", value: client.serviceStatus)
                LabeledContent("Бинарник агента", value: client.agentBinaryExists ? "на месте" : "нет")
                LabeledContent("plist", value: client.agentPlistExists ? "на месте" : "нет")
                HStack {
                    Button("Зарегистрировать") { client.register() }
                    Button("Снять регистрацию") { client.unregister() }
                    Button("Открыть Объекты входа") { client.openLoginItems() }
                    Button("Обновить статус") { client.refreshStatus() }
                }
                Text("Шаги переноса и подмены версии — в README, FS-7. Этот экран только показывает живой статус. Запускайте копию из ~/Applications, не из DerivedData.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LogList(lines: client.lines)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .textSelection(.enabled)
        }
    }
}
