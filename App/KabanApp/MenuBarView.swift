import SwiftUI
import ServiceManagement
import UserNotifications
import KabanBoardCore
import KabanProtocol

struct MenuBarView: View {
    @Bindable var runtime: DaemonRuntime
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var waiting: [TaskCard] {
        (runtime.store?.projection?.tasks.values.filter { $0.state.status == .waitingHuman } ?? []).sorted {
            if $0.projectId != $1.projectId { return $0.projectId.rawValue < $1.projectId.rawValue }
            return $0.id.rawValue < $1.id.rawValue
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Kaban", systemImage: "list.bullet.rectangle").font(.headline)
                    Spacer()
                    if let store = runtime.store, let settings = store.projection?.settings {
                        Text("Резервирования \(store.reservationCount)/\(settings.maxConcurrentRuns)").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Слоты неизвестны").font(.caption).foregroundStyle(.secondary) }
                }
                if let store = runtime.store {
                    if let label = store.connectionLabel { Text(label).font(.callout).foregroundStyle(.orange) }
                    if store.projection?.settings?.quotaOptions.enabled == true {
                        QuotaBarsView(store: store, theme: theme, compact: true)
                            .padding(10).background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if store.projection?.settings?.quotaOptions.enabled == true, let fetched = store.projection?.ephemeral.quota?.fetchedAt {
                        Text("Данные источника: " + fetched.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.abbreviated).hour().minute())).font(.caption).foregroundStyle(.secondary)
                    }
                    SchedulerFlagsView(store: store, theme: theme, onNavigate: showBoard)
                    ForEach(store.projection?.projectOrder ?? [], id: \.self) { project in
                        if store.projection?.ephemeral.schedulerFlags.contains(where: { SchedulerFlagPresentation($0).project == project }) == true {
                            Text(store.projection?.projects[project]?.name ?? project.rawValue).font(.caption.bold())
                            SchedulerFlagsView(store: store, theme: theme, project: project, onNavigate: showBoard)
                        }
                    }
                    Label(store.projection == nil ? "Ждут человека: нет данных" : "Ждут человека: \(store.waitingCount)", systemImage: "hand.raised").font(.headline)
                    if store.projection == nil { Text("Загрузка задач…").foregroundStyle(.secondary) }
                    else if waiting.isEmpty { Text("Все задачи продолжаются без вашего участия.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(waiting, id: \.id) { card in
                        Button {
                            showBoard()
                            store.screen = .board; store.focusProject(card.projectId)
                            Task { await store.select(card.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.title).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                Text((store.projection?.projects[card.projectId]?.name ?? card.projectId.rawValue) + " · " + CardPresentation(state: card.state).label)
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                    Divider()
                    Button("Открыть доску", systemImage: "rectangle.split.3x1") { store.screen = .board; showBoard() }
                    Button(store.macPaused ? "Продолжить новые запуски" : "Пауза новых запусков", systemImage: store.macPaused ? "play" : "pause") {
                        Task { await store.toggleMacPause() }
                    }.disabled(!store.can(store.macPaused ? .resumeAll : .pauseAll))
                    Button("Настройки этого Мака…", systemImage: "slider.horizontal.3") { store.screen = .quota; showBoard() }
                    Toggle("Уведомлять о требующих внимания задачах", isOn: Binding(get: { store.attention.enabled }, set: { runtime.notifications.setEnabled($0) }))
                    if let error = store.attention.error { Text(error).font(.caption).foregroundStyle(.orange) }
                } else {
                    Text(runtime.failure ?? runtime.status).font(.callout).foregroundStyle(.secondary)
                    Button("Открыть настройку Kaban…") { runtime.showSetup = true; showBoard() }
                }
                if let status = runtime.onboardingSystem.notifications {
                    if status == .denied { Text("macOS запретила уведомления. Задачи и менюбар продолжают работать.").font(.caption).foregroundStyle(.secondary) }
                    else if status == .notDetermined {
                        Button("Разрешить уведомления…") { Task { await runtime.onboardingSystem.requestNotifications() } }
                            .disabled(runtime.onboardingSystem.busy || BoardQA.isActive)
                    }
                }
                if let loginStatus = runtime.onboardingSystem.loginStatus {
                    Toggle("Открывать Kaban при входе", isOn: Binding(get: { loginStatus == .enabled }, set: { value in Task { await runtime.onboardingSystem.setAutoLaunch(value) } }))
                        .disabled(runtime.onboardingSystem.busy || runtime.developer || runtime.fixture || BoardQA.isActive || loginStatus == .requiresApproval)
                    if loginStatus == .requiresApproval {
                        Text("Разрешите автозапуск Kaban в «Объектах входа».").font(.caption).foregroundStyle(.secondary)
                        Button("Объекты входа…") { runtime.openSettings() }
                    }
                } else { Text("Проверка автозапуска…").font(.caption).foregroundStyle(.secondary) }
                if let error = runtime.onboardingSystem.loginError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let error = runtime.onboardingSystem.notificationError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let message = runtime.notifications.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if let inbox = runtime.notifications.inbox {
                    if let reply = inbox.reply { Text(reply).font(.callout).textSelection(.enabled) }
                    HStack {
                        Button("Повторить переход") { runtime.notifications.retryInbox() }
                        Button("Убрать сохранённый ответ") { runtime.notifications.dismissInbox() }
                    }
                }
                Divider()
                Button("Завершить Kaban") { NSApp.terminate(nil) }
                Text("Закрытие окна оставляет клиент в менюбаре. Завершение клиента не отключает установленную службу.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }.frame(width: 420, height: 620)
            .onAppear {
                let open = openWindow
                runtime.presentBoard = { [weak runtime] in runtime?.revealBoard { open(id: "board") } }
                Task { await runtime.onboardingSystem.refresh(fixture: BoardQA.isActive) }
            }
    }
    private func showBoard() { runtime.revealBoard { openWindow(id: "board") } }
}
