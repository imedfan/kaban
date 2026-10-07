import SwiftUI
import ServiceManagement
import UserNotifications
import Observation
import KabanProtocol
import KabanBoardCore

@MainActor @Observable final class OnboardingSystemState {
    var notifications: UNAuthorizationStatus?
    var loginStatus: SMAppService.Status?
    var notificationError: String?
    var loginError: String?
    var busy = false
    func refresh(fixture: Bool) async {
        if fixture { notifications = .notDetermined; loginStatus = .notRegistered; return }
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        loginStatus = SMAppService.mainApp.status
    }
    func requestNotifications() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notificationError = nil
        } catch { notificationError = error.localizedDescription }
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func setAutoLaunch(_ enabled: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = SMAppService.mainApp.status
    }
}

/// One setup surface serves first launch and later environment repair.
struct OnboardingView: View {
    @Bindable var runtime: DaemonRuntime
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var system: OnboardingSystemState { runtime.onboardingSystem }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ReferenceWordmark().fill(theme.text).frame(width: 110, height: 30)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Подготовим Kaban к работе").font(.system(size: 25, weight: .semibold))
                        Text("Подключим локальную службу и проверим Cursor. Уведомления и автозапуск можно настроить позже.")
                            .font(.system(size: 13)).foregroundStyle(theme.secondary).lineSpacing(3)
                    }
                    section("Локальная служба", symbol: "externaldrive.badge.wifi") {
                        HStack(alignment: .top, spacing: 10) {
                            if connecting { ProgressView().controlSize(.small) }
                            else { Image(systemName: runtime.store?.canSend == true ? "checkmark.circle.fill" : "exclamationmark.triangle").foregroundStyle(theme.status(runtime.store?.canSend == true ? "done" : "waiting").2) }
                            Text(runtime.store?.canSend == true ? "Соединение установлено" : (runtime.store?.connectionLabel ?? runtime.status))
                                .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        }
                        if let failure = runtime.failure { explanation(failure) }
                        if runtime.store?.canSend != true {
                            HStack(spacing: 10) {
                                if !runtime.developer {
                                    Button("Объекты входа…") { runtime.openSettings() }.buttonStyle(KabanButtonStyle())
                                }
                                Button("Проверить снова") { Task { await runtime.retry() } }
                                    .buttonStyle(KabanButtonStyle(primary: true)).disabled(connecting)
                            }
                        }
                        explanation(runtime.developer ? "Режим разработки · отдельная БД" : runtime.fixture ? "Демонстрация · данные в памяти" : "Задачи и настройки сохраняются локальной службой на этом Маке.")
                    }
                    if let environment = runtime.store?.environment {
                        OnboardingEnvironmentView(environment: environment, theme: theme)
                    } else {
                        section("Cursor и окружение", symbol: "terminal") {
                            explanation("Проверим путь, версию и вход в Cursor после подключения службы.")
                        }
                    }
                    section("Работа в фоне", symbol: "bell") {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Уведомления").font(.system(size: 13, weight: .medium))
                                explanation(notificationDescription)
                            }
                            Spacer(minLength: 10)
                            if system.notifications == .notDetermined {
                                Button("Разрешить…") { Task { await system.requestNotifications() } }
                                    .buttonStyle(KabanButtonStyle()).disabled(system.busy || runtime.fixture)
                            }
                        }
                        if let failure = system.notificationError { explanation(failure) }
                        Divider().overlay(theme.line)
                        Toggle("Открывать Kaban при входе на Мак", isOn: Binding(get: { system.loginStatus == .enabled }, set: { value in Task { await system.setAutoLaunch(value) } }))
                            .toggleStyle(.checkbox).font(.system(size: 13))
                            .disabled(system.busy || runtime.developer || runtime.fixture || system.loginStatus == nil || system.loginStatus == .requiresApproval)
                        if system.loginStatus == .requiresApproval {
                            explanation("Разрешите автозапуск Kaban в «Объектах входа».")
                            Button("Объекты входа…") { runtime.openSettings() }.buttonStyle(KabanButtonStyle())
                        }
                        if let failure = system.loginError { explanation(failure) }
                    }
                }.padding(28).frame(maxWidth: 760, alignment: .leading)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: DesignSystem.panelRadius))
                    .overlay(RoundedRectangle(cornerRadius: DesignSystem.panelRadius).stroke(theme.line, lineWidth: 0.5))
                    .padding(.horizontal, 32).padding(.vertical, 28).frame(maxWidth: .infinity)
            }
            HStack(spacing: 20) {
                Text("Проверку Cursor и уведомления можно завершить позже. Backlog можно вести, пока Cursor недоступен.")
                    .font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button("Открыть доску") { runtime.finishSetup() }
                    .buttonStyle(KabanButtonStyle(primary: true)).disabled(runtime.store?.canSend != true)
                    .keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 32).padding(.vertical, 16).background(theme.card)
                .overlay(alignment: .top) { theme.line.frame(height: 0.5) }
        }.background(ReferenceBackdrop(theme: theme)).foregroundStyle(theme.text)
            .task { await system.refresh(fixture: runtime.fixture) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await system.refresh(fixture: runtime.fixture) } } }
    }
    private var connecting: Bool {
        if runtime.busy { return true }
        switch runtime.store?.connectionState {
        case .connecting, .synchronizing, .reconnecting: return true
        default: return false
        }
    }
    private var notificationDescription: String {
        switch system.notifications {
        case .notDetermined: "Можно пропустить. Уведомления понадобятся, когда задача ждёт вашего решения."
        case .denied: "Выключены. Включить можно в Системных настройках → Уведомления → Kaban."
        case .authorized, .provisional, .ephemeral: "Разрешены для Kaban."
        default: "Проверяем разрешение macOS…"
        }
    }
    private func explanation(_ value: String) -> some View {
        Text(value).font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            content()
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.control, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OnboardingEnvironmentView: View {
    @Bindable var environment: RunnerEnvironmentStore
    let theme: ReferenceTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Cursor и окружение", systemImage: "terminal").font(.system(size: 14, weight: .semibold))
                Spacer()
                if environment.isChecking { ProgressView().controlSize(.small) }
            }
            if environment.isStale { note("Показана последняя проверка. После подключения обновим данные.") }
            if let reason = environment.runnerReason { note(reasonText(reason)) }
            if let report = environment.report {
                fact("Cursor CLI", value: report.cursorAgentPath ?? "Не найден")
                fact("Версия", value: report.version ?? "Не удалось проверить")
                fact("Аккаунт Cursor", value: report.authOK ? "Вход выполнен" : "Вход не подтверждён")
                fact("Git", value: report.gitVersion ?? "Недоступен")
                fact("Среда запуска", value: report.sandboxOK ? "Проверена" : "Недоступна")
                if !report.authOK, report.cursorAgentPath != nil {
                    note("Выполните вход в Терминале, затем проверьте снова:")
                    Text(loginCommand(report.cursorAgentPath)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let checked = environment.checkedAt {
                    Text("Проверено \(checked.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(theme.faint)
                }
            }
            if let failure = environment.reportError { note(failure) }
            Divider().overlay(theme.line)
            Text("Путь к cursor-agent").font(.system(size: 12, weight: .medium))
            HStack(spacing: 10) {
                TextField("Автоматический поиск", text: Binding(get: { environment.draftPath }, set: { environment.editPath($0) }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .disabled(environment.configuration == nil || !environment.session.can(.configureCursor))
                Button("Выбрать…") { chooseExecutable() }.buttonStyle(KabanButtonStyle())
                    .disabled(environment.configuration == nil || !environment.session.can(.configureCursor))
                Button("Сохранить") { Task { await environment.savePath() } }.buttonStyle(KabanButtonStyle())
                    .disabled(!environment.canConfigure)
            }
            if let failure = environment.configurationUnavailableReason { note(failure) }
            if let phase = environment.submissionPhase {
                switch phase {
                case .sending: note("Сохраняем путь…")
                case .deliveryUncertain: note("Исход сохранения неизвестен. Проверим прежнюю отправку после подключения.")
                case .awaitingEvent: note("Ждём подтверждения сохранённого пути от службы.")
                case .applied where !environment.isEdited: note("Путь сохранён службой Kaban.")
                default: EmptyView()
                }
            }
            Button("Проверить снова") {
                Task {
                    if environment.canRecheck { await environment.recheck() }
                    await environment.refresh()
                }
            }.buttonStyle(KabanButtonStyle()).disabled(environment.isChecking || !environment.session.canSend || (!environment.session.can(CommandName.checkEnvironment) && !environment.canRecheck))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.control, in: RoundedRectangle(cornerRadius: 10))
            .onAppear { if environment.session.canSend { Task { await environment.refresh() } } }
            .onChange(of: environment.session.connectionState) { _, state in
                if state == .connected { Task { await environment.refresh() } }
            }
            .onChange(of: environment.submissionPhase) { _, phase in
                if phase == .applied { Task { await environment.refresh() } }
            }
    }
    private func fact(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).frame(width: 120, alignment: .leading).foregroundStyle(theme.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
    private func note(_ value: String) -> some View {
        Text(value).font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func reasonText(_ reason: RunnerUnavailableReason) -> String {
        switch reason {
        case .agentMissing: "Cursor CLI не найден. Укажите путь к cursor-agent."
        case .agentNotRunnable: "Cursor CLI не запускается. Проверьте executable и разрешения."
        case .agentNotLoggedIn, .runnerAuth: "Вход в Cursor не выполнен или истёк. Выполните cursor-agent login в Терминале."
        }
    }
    private func loginCommand(_ path: String?) -> String {
        guard let path else { return "cursor-agent login" }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' login"
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "Выбрать"; panel.message = "Выберите исполняемый файл cursor-agent. Путь проверит служба Kaban."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        environment.editPath(url.path)
    }
}
