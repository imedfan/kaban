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
    var showSetup = true
    let onboardingSystem = OnboardingSystemState()
    private var initialization: Task<Void, Never>?
    private var closeTransport: (() async -> Void)?
    private var started = false
    private var connectingInstalled = false
    private let service = SMAppService.agent(plistName: DaemonInstallation.plistName)
    var developer: Bool { CommandLine.arguments.contains("--developer") || BoardQA.argument("--daemon-smoke") != nil }
    var fixture: Bool { BoardQA.isActive && BoardQA.argument("--qa-runtime-state") == nil && BoardQA.argument("--daemon-smoke") == nil && !developer }
    private var setupKey: String { "onboarding.completed." + (developer ? "developer" : "installed") }
    func finishSetup() {
        guard store?.canSend == true else { return }
        showSetup = false
        if !fixture && !BoardQA.isActive { UserDefaults.standard.set(true, forKey: setupKey) }
    }
    init() {
        showSetup = BoardQA.argument("--qa-onboarding") != nil || (!BoardQA.isActive && !UserDefaults.standard.bool(forKey: setupKey))
        if fixture {
            let base = AppFixture.client()
            let client: any KabanClient
            if let state = BoardQA.argument("--qa-onboarding"), state != "unavailable" { client = QAEnvironmentClient(base: base, state: state) }
            else { client = base }
            store = BoardStore(client: client, storage: MemoryKeyValueStore(), fixture: true)
        }
        if let state = BoardQA.argument("--qa-runtime-state"), !CommandLine.arguments.contains("--qa-incompatible-daemon") {
            status = state == "protocol-error" ? "Служба Kaban требует обновления" : "Не удалось подключиться к службе Kaban"
            if state == "approval" { status = "Разрешите Kaban в настройках «Объекты входа и расширения»" }
            failure = state == "approval" ? nil : state == "protocol-error" ? "Несовместимая версия протокола. Обновите службу Kaban и проверьте подключение снова." : "macOS не смогла включить локальную службу. Откройте «Объекты входа и расширения», проверьте разрешение для Kaban и повторите подключение. Сохранённые задачи останутся в локальной базе."
        }
    }
    func start() {
        guard !started else { return }; started = true
        BoardQA.runtime = self
        initialization = Task { await initializeRuntime(); initialization = nil }
    }
    private func initializeRuntime() async {
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
        busy = true; defer { busy = false }
        observeStatus()
        if service.status != .enabled, store != nil {
            store?.stop(); store = nil
            await closeTransport?(); closeTransport = nil
        }
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
    var body: some View {
        Group {
            if let store = runtime.store, !runtime.showSetup {
                BoardView(store: store).onAppear { BoardQA.store = store }
            } else {
                OnboardingView(runtime: runtime).onAppear { BoardQA.store = runtime.store }
            }
        }
        .task { runtime.start() }
        .onChange(of: runtime.store.map { ObjectIdentifier($0) }, initial: true) { _, _ in
            BoardQA.store = runtime.store
            if let store = runtime.store { Task { await store.connect() } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await runtime.refresh() } } }
    }
}
