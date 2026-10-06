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
    private let service = SMAppService.agent(plistName: DaemonInstallation.plistName)
    var developer: Bool { CommandLine.arguments.contains("--developer") || BoardQA.argument("--daemon-smoke") != nil }
    var fixture: Bool { BoardQA.isActive && BoardQA.argument("--daemon-smoke") == nil && !developer }
    init() { if fixture { store = BoardStore(client: AppFixture.client(), storage: MemoryKeyValueStore()) } }
    func start() async {
        guard !started else { return }; started = true
        BoardQA.runtime = self
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
            try await service.unregister(); created = false; store = nil
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
        guard started, !fixture, !developer, !busy else { return }
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
                store = nil; await closeTransport?(); closeTransport = nil
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
            store = nil; await closeTransport?(); closeTransport = nil
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
        guard store == nil else { return }
        let connection = XPCDaemonTransport(appBundle: Bundle.main.bundleURL); closeTransport = { await connection.close() }
        do {
            let client = DaemonKabanClient(transport: connection)
            _ = try await client.getSnapshot()
            store = BoardStore(client: client); failure = nil
        } catch { await connection.close(); closeTransport = nil; failure = error.localizedDescription }
    }
    private func connectDeveloper() async {
        do {
            let installation = DaemonInstallation(developer: true)
            let path = BoardQA.argument("--developer-database") ?? installation.database.path
            if BoardQA.argument("--developer-database") == nil { try installation.prepare() }
            else { try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KabanDaemon")
            let connection = StdioDaemonTransport(executable: helper, database: path, additionalArguments: ["--initialize"]); closeTransport = { await connection.close() }
            let client = DaemonKabanClient(transport: connection); _ = try await client.getSnapshot()
            if let project = BoardQA.argument("--daemon-smoke-project") {
                let result = try await client.send(.addProject(path: project, createTemplate: true), commandId: UUID())
                if case .error(let error) = result { throw error }
                _ = try await client.send(.pauseAll, commandId: UUID())
            }
            store = BoardStore(client: client, storage: BoardQA.isActive ? MemoryKeyValueStore() : DefaultsStorage())
            status = "Developer mode · private stdio"
        } catch { failure = error.localizedDescription; status = "Не удалось запустить встроенную службу" }
    }
}
struct DaemonRuntimeView: View {
    @Bindable var runtime: DaemonRuntime
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if let store = runtime.store {
                VStack(spacing: 0) {
                    if !store.canSend {
                        Text("Соединение с Kaban восстанавливается. Действия будут доступны после синхронизации.")
                            .font(.callout).padding(10).frame(maxWidth: .infinity).background(.quaternary)
                    }
                    BoardView(store: store).onAppear { BoardQA.store = store }
                }
            } else {
                VStack(spacing: 18) {
                    Text("Служба Kaban").font(.title2)
                    Text(runtime.status).multilineTextAlignment(.center)
                    if let failure = runtime.failure { Text(failure).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        Button("Открыть объекты входа") { runtime.openSettings() }
                        Button("Проверить снова") { Task { await runtime.retry() } }.disabled(runtime.busy)
                    }
                }.padding(36).frame(maxWidth: 620).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await runtime.start() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await runtime.refresh() } } }
    }
}
