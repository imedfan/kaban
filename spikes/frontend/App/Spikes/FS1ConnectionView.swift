import SwiftUI

struct FS1ConnectionView: View {
    @State private var client = SpikeAgentClient.shared

    var body: some View {
        SpikeScreen(
            code: "FS-1",
            title: "XPCSession и SMAppService",
            instruments: "Instruments: os_signpost / Points of Interest (FS1.Ping). Время ping — в журнале. Console: subsystem app.kaban.spikes."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                banner
                HStack(spacing: 8) {
                    Button("Зарегистрировать") { client.register() }
                    Button("Снять регистрацию") { client.unregister() }
                    Button("Объекты входа") { client.openLoginItems() }
                    Button("Подключиться") { client.connect() }
                    Button("Убить демон") { client.killAgent() }
                    Button("Обрезать журнал") { client.trimJournal() }
                    Button("Событие") { client.appendNote("ui") }
                }
                Toggle("Автопереподключение 0.5 → 1 → 2 → 5 с", isOn: Bindable(client).autoReconnect)
                    .toggleStyle(.checkbox)
                Text("фаза \(client.phase) · status \(client.serviceStatus) · seq \(client.lastSeq) · pid \(client.lastPid)")
                    .font(.caption.monospaced())
                Text("Team ID: \(client.teamID)")
                    .font(.caption)
                bundleRow("бинарник агента", client.agentBinaryExists, client.agentBinaryPath)
                bundleRow("plist LaunchAgent", client.agentPlistExists, client.agentPlistPath)
                Text("Mach \(SpikeIdentity.machService). Контракт одноразовый, не KabanProtocol. Рядом в тот же день — бэкенд-спайк 3, другим процессом.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LogList(lines: client.lines)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var banner: some View {
        let missingTeam = SigningProbe.teamIdentifier() == nil
        return Text(missingTeam
            ? "Нет Team ID. Для FS-1 нужна подпись Apple Development, не ad-hoc: launchd отклонит агента."
            : "Подпись с Team ID есть. Ожидаемый ход: register → одобрение → ping → kill → новый bootID и resyncRequired.")
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(missingTeam ? Color.orange.opacity(0.25) : Color.green.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func bundleRow(_ title: String, _ ok: Bool, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
