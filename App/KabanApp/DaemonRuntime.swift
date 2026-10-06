import SwiftUI
import Observation
import ServiceManagement
import Darwin
import KabanProtocol
import KabanBoardCore
import KabanTransport

@MainActor @Observable final class DaemonRuntime {
    var store: BoardStore?
    var status = "Подключение службы Kaban…"
    var failure: String?
    var busy = false
    private var closeTransport: (() async -> Void)?
    private var started = false
    private var connectingInstalled = false
    private let service = SMAppService.agent(plistName: DaemonInstallation.plistName)
    var developer: Bool { CommandLine.arguments.contains("--developer") || BoardQA.argument("--daemon-smoke") != nil }
    var fixture: Bool { BoardQA.isActive && BoardQA.argument("--qa-runtime-state") == nil && BoardQA.argument("--daemon-smoke") == nil && !developer }
    init() {
        if fixture { store = BoardStore(client: AppFixture.client(), storage: MemoryKeyValueStore()) }
        if let state = BoardQA.argument("--qa-runtime-state"), !CommandLine.arguments.contains("--qa-incompatible-daemon") {
            status = state == "protocol-error" ? "Служба Kaban требует обновления" : "Не удалось подключиться к службе Kaban"
            failure = state == "protocol-error" ? "Несовместимая версия протокола. Обновите службу Kaban и проверьте подключение снова." : "macOS не смогла включить локальную службу. Откройте «Объекты входа и расширения», проверьте разрешение для Kaban и повторите подключение. Сохранённые задачи останутся в локальной базе."
        }
    }
    func start() async {
        guard !started else { return }; started = true
        BoardQA.runtime = self
        if BoardQA.argument("--qa-runtime-state") != nil, !CommandLine.arguments.contains("--qa-incompatible-daemon") { return }
        if fixture { return }
        if let report = BoardQA.argument("--service-smoke") { await serviceSmoke(report); return }
        if developer { await connectDeveloper(); return }
        await registerIfNeeded()
    }
    private func serviceSmoke(_ report: String) async {
        let before = service.status
        var values: [String: Any] = ["before": serviceStatusName(before)]
        var created = false
        do {
            guard before == .notRegistered || before == .notFound else {
                throw NSError(domain: "ServiceQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Existing service was preserved; use an unregistered test bundle"])
            }
            _ = try BundledDaemonIdentity.requirement(appBundle: Bundle.main.bundleURL, forHelper: true)
            try service.register(); created = true; observeStatus()
            values["registered"] = serviceStatusName(service.status)
            if service.status == .enabled {
                await connectInstalled()
                values["xpc"] = store != nil ? "connected" : (failure ?? "failed")
            }
            try await service.unregister(); created = false; store?.stop(); store = nil
            await closeTransport?(); closeTransport = nil; observeStatus()
            values["unregistered"] = serviceStatusName(service.status)
            values["result"] = "observed"
        } catch {
            values["error"] = String(describing: error)
            values["status"] = serviceStatusName(service.status)
            if created || ((before == .notRegistered || before == .notFound) && (service.status == .enabled || service.status == .requiresApproval)) { try? await service.unregister() }
            values["result"] = "failed"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            if report == "-" { FileHandle.standardOutput.write(data + Data([10])) }
            else { try data.write(to: URL(fileURLWithPath: report)) }
        } catch { FileHandle.standardError.write(Data("Service QA report failed: \(error)\n".utf8)) }
        Darwin.exit(values["result"] as? String == "observed" ? EXIT_SUCCESS : EXIT_FAILURE)
    }
    func refresh() async {
        guard started, !fixture, !developer, !busy, BoardQA.argument("--qa-runtime-state") == nil else { return }
        observeStatus()
        if service.status == .enabled, store == nil { await connectInstalled() }
    }
    private func serviceStatusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
    private func observeStatus() {
        switch service.status {
        case .enabled: status = "Служба Kaban включена"
        case .requiresApproval: status = "Разрешите Kaban в настройках «Объекты входа и расширения»"
        case .notRegistered: status = "Служба Kaban отключена"
        case .notFound: status = "macOS не нашла встроенную службу Kaban"
        @unknown default: status = "Неизвестное состояние службы Kaban"
        }
    }
    func registerIfNeeded() async {
        guard !busy, !developer, !fixture else { return }; busy = true; defer { busy = false }; failure = nil
        do {
            _ = try BundledDaemonIdentity.requirement(appBundle: Bundle.main.bundleURL, forHelper: true)
            let identity = try BundledDaemonIdentity.inspect(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KabanDaemon"), identifier: DaemonInstallation.helperIdentifier)
            let fingerprint = identity.hashes.map { $0.base64EncodedString() }.sorted().joined(separator: ":")
            let key = "daemon.installed-helper-hash"
            if UserDefaults.standard.string(forKey: key) != fingerprint,
               service.status == .enabled || service.status == .requiresApproval {
                store?.stop(); store = nil; await closeTransport?(); closeTransport = nil
                try await service.unregister()
            }
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            if service.status == .enabled || service.status == .requiresApproval { UserDefaults.standard.set(fingerprint, forKey: key) }
            observeStatus()
            if service.status == .enabled { await connectInstalled() }
        } catch { failure = error.localizedDescription; observeStatus() }
    }
    func unregister() async {
        guard !busy, !developer, !fixture else { return }; busy = true; defer { busy = false }
        do {
            store?.stop(); store = nil; await closeTransport?(); closeTransport = nil
            try await service.unregister(); failure = nil; observeStatus()
        } catch { failure = error.localizedDescription; observeStatus() }
    }
    func retry() async {
        if developer { await connectDeveloper() } else { await registerIfNeeded() }
    }
    func restart() async {
        guard !developer, !fixture else { return }
        await unregister()
        guard failure == nil else { return }
        await registerIfNeeded()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
    private func connectInstalled() async {
        guard store == nil, !connectingInstalled else { return }
        connectingInstalled = true; defer { connectingInstalled = false }
        let connection = XPCDaemonTransport(appBundle: Bundle.main.bundleURL); closeTransport = { await connection.close() }
        do {
            let client = DaemonKabanClient(transport: connection)
            try await client.capabilities().requireSession()
            _ = try await client.getSnapshot()
            store = BoardStore(client: client, dataSourceDetail: DaemonInstallation().database.path); failure = nil
        } catch {
            await connection.close(); closeTransport = nil
            failure = (error as? CommandError)?.message ?? error.localizedDescription
            if let error = error as? CommandError,
               [CommandError.protocolMismatchCode, CommandError.unsupportedOperationCode].contains(error.code) {
                status = "Служба Kaban требует обновления"
            }
        }
    }
    private func connectDeveloper() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        store?.stop(); store = nil
        await closeTransport?(); closeTransport = nil
        failure = nil
        do {
            let installation = DaemonInstallation(developer: true)
            let path = BoardQA.argument("--developer-database") ?? installation.database.path
            if BoardQA.argument("--developer-database") == nil { try installation.prepare() }
            else { try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KabanDaemon")
            let connection = StdioDaemonTransport(executable: helper, database: path, additionalArguments: ["--initialize"]); closeTransport = { await connection.close() }
            let transport: any DaemonTransport
            if CommandLine.arguments.contains("--qa-lose-create-reply") { transport = QAReplyLossTransport(base: connection) }
            else if CommandLine.arguments.contains("--qa-incompatible-daemon") { transport = QAIncompatibleTransport(base: connection) }
            else { transport = connection }
            let client = DaemonKabanClient(transport: transport); _ = try await client.getSnapshot()
            try await client.capabilities().requireSession()
            if let project = BoardQA.argument("--daemon-smoke-project") {
                let result = try await client.send(.addProject(path: project, createTemplate: true), commandId: UUID())
                if case .error(let error) = result { throw error }
                _ = try await client.send(.pauseAll, commandId: UUID())
            }
            store = BoardStore(client: client, storage: BoardQA.isActive ? MemoryKeyValueStore() : DefaultsStorage(),
                               dataSource: "Режим разработки · отдельная БД", dataSourceDetail: path,
                               commandStorageKey: "client.commands.developer.\(URL(fileURLWithPath: path).standardizedFileURL.path)")
            status = "Developer mode · private stdio"
        } catch {
            await closeTransport?(); closeTransport = nil
            failure = (error as? CommandError)?.message ?? error.localizedDescription
            if let error = error as? CommandError,
               [CommandError.protocolMismatchCode, CommandError.unsupportedOperationCode].contains(error.code) {
                status = "Служба Kaban требует обновления"
            } else { status = "Не удалось подключиться к службе Kaban" }
        }
    }
}
struct DaemonRuntimeView: View {
    @Bindable var runtime: DaemonRuntime
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        Group {
            if let store = runtime.store {
                VStack(spacing: 0) {
                    BoardView(store: store).onAppear { BoardQA.store = store }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ReferenceWordmark().fill(theme.text).frame(width: 110, height: 30)
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Подключение к Kaban", systemImage: "externaldrive.badge.wifi")
                                .font(.system(size: 22, weight: .semibold))
                            Text("Задачи и настройки хранятся в локальной службе. Подключите её, чтобы открыть доску.")
                                .font(.system(size: 13)).foregroundStyle(theme.secondary).lineSpacing(4)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                if runtime.busy { ProgressView().controlSize(.small) }
                                else { Image(systemName: runtime.failure == nil ? "info.circle" : "exclamationmark.triangle").foregroundStyle(theme.status("waiting").2) }
                                Text(runtime.status).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            }
                            if let failure = runtime.failure {
                                Text(failure).font(.system(size: 12)).foregroundStyle(theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.control, in: RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 10) {
                            if !runtime.developer {
                                Button("Объекты входа…") { runtime.openSettings() }.buttonStyle(KabanButtonStyle())
                            }
                            Button("Проверить снова") { Task { await runtime.retry() } }
                                .buttonStyle(KabanButtonStyle(primary: true)).disabled(runtime.busy).keyboardShortcut(.defaultAction)
                        }
                        Text(runtime.developer ? "Режим разработки · отдельная БД" : "Локальная служба · на этом Маке")
                            .font(.system(size: 11)).foregroundStyle(theme.faint)
                    }.padding(32).frame(maxWidth: 560, alignment: .leading)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: DesignSystem.panelRadius))
                        .overlay(RoundedRectangle(cornerRadius: DesignSystem.panelRadius).stroke(theme.line, lineWidth: 0.5))
                        .padding(.horizontal, 32).padding(.vertical, 64).frame(maxWidth: .infinity)
                }.background(ReferenceBackdrop(theme: theme)).foregroundStyle(theme.text)
            }
        }
        .task { await runtime.start() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await runtime.refresh() } } }
    }
}
