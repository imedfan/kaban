import SwiftUI
import KabanProtocol
import KabanBoardCore

struct IncidentsView: View {
    @Bindable var store: BoardStore
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(store.projection.map { "Открыто: \($0.openIncidentCount)" } ?? "Количество неизвестно").font(.headline)
                    Spacer()
                    Button { store.incidents.scheduleRefresh() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить инциденты")
                }
                Picker("История", selection: Binding(get: { store.incidents.filter }, set: { store.incidents.filter = $0 })) {
                    Text("Открытые").tag(IncidentListState.open)
                    Text("Все").tag(IncidentListState.all)
                }.pickerStyle(.segmented)
                IncidentReadNotice(store: store)
                if store.incidents.visible.isEmpty, store.incidents.isCurrent {
                    ContentUnavailableView(store.incidents.filter == .open ? "Нет открытых инцидентов" : "История пуста", systemImage: "checkmark.shield")
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.incidents.visible, id: \.id) { incident in
                            Button {
                                store.incidents.selectedID = incident.id
                                Task { await store.select(incident.taskId) }
                            } label: {
                                IncidentRow(store: store, incident: incident, theme: theme)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.bottom, 16)
                }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let incident = store.incidents.selected {
                theme.line.frame(width: 1)
                Group {
                    if store.selectedID == incident.taskId, store.projection?.tasks[incident.taskId] != nil {
                        TaskDetailView(store: store, openSheet: { store.sheet = $0 })
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Text("История инцидента").font(.headline); Spacer(); Button("Закрыть") { store.incidents.selectedID = nil } }
                                IncidentDetailBlock(store: store, incident: incident)
                                Text("Задача недоступна. Запись инцидента сохранена.").foregroundStyle(theme.secondary)
                            }.padding(16)
                        }
                    }
                }.frame(width: 400)
            }
        }
    }
}

private struct IncidentReadNotice: View {
    @Bindable var store: BoardStore
    var body: some View {
        switch store.incidents.readState {
        case .unknown: Text("Список ещё не прочитан.").font(.caption)
        case .loading: HStack { ProgressView().controlSize(.small); Text("Читаем историю…").font(.caption) }
        case .loaded:
            if !store.incidents.isCurrent { Text("Список требует обновления. Действия временно недоступны.").font(.caption) }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption)
                if !store.incidents.records.isEmpty { Text("Показана последняя прочитанная история.").font(.caption) }
                Button("Повторить чтение") { store.incidents.scheduleRefresh() }.buttonStyle(KabanButtonStyle())
            }
        }
    }
}

struct IncidentRow: View {
    @Bindable var store: BoardStore
    let incident: Incident
    let theme: ReferenceTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(store.mascot(incident.projectId).emoji)
                Text(store.projection?.projects[incident.projectId]?.name ?? "Проект недоступен · \(incident.projectId.rawValue)").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let count = store.projection?.projects[incident.projectId]?.openIncidentCount { Text("\(count)").font(.caption.monospacedDigit()).help("Открытые инциденты проекта") }
            }
            Text(store.projection?.tasks[incident.taskId]?.title ?? incident.taskId.rawValue).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading)
            Label(incident.kind.title, systemImage: incident.resolvedAt == nil ? "light.beacon.max" : "checkmark.shield")
                .font(.system(size: 12)).foregroundStyle(incident.resolvedAt == nil ? theme.status("incident").2 : theme.secondary)
            Text(incident.openedAt.incidentDate).font(.caption).foregroundStyle(theme.secondary)
            Text(incident.runId.map { "Run \($0.rawValue)" } ?? "Run не указан").font(.caption.monospaced()).lineLimit(2)
            if incident.resolvedAt != nil { Text(incident.resolution?.title ?? "Разобран · действие не сообщено").font(.caption).foregroundStyle(theme.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(theme.dark ? theme.window : Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.incidents.selectedID == incident.id ? theme.accent : theme.line, lineWidth: store.incidents.selectedID == incident.id ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("\(incident.kind.title), задача \(incident.taskId.rawValue), \(incident.resolvedAt == nil ? "открыт" : "разобран")")
    }
}

struct IncidentDetailBlock: View {
    @Bindable var store: BoardStore
    let incident: Incident
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(incident.kind.title, systemImage: "light.beacon.max").font(.headline).foregroundStyle(theme.status("incident").2)
            Text("\(incident.openedAt.incidentDate) · \(incident.taskId.rawValue)").font(.caption).textSelection(.enabled)
            if let run = incident.runId {
                HStack {
                    Text("Run \(run.rawValue)").font(.caption.monospaced()).textSelection(.enabled)
                    if let source = store.detail?.runs.first(where: { $0.id == run }) {
                        Button("Лог") { store.logRunRoute = source }.buttonStyle(KabanButtonStyle())
                    } else { Text("Лог недоступен").font(.caption).foregroundStyle(theme.secondary) }
                }
            } else { Text("Run не указан. Лог недоступен.").font(.caption).foregroundStyle(theme.secondary) }
            if incident.rolledBack.isEmpty { Text("Backend не сообщил откат объектов.").font(.callout) }
            else {
                Text("Backend выполнил откат").font(.system(size: 12, weight: .semibold))
                ForEach(Array(incident.rolledBack.enumerated()), id: \.offset) { _, path in Text(path).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let resolved = incident.resolvedAt {
                Text("Разобран \(resolved.incidentDate)").font(.callout)
                Text(incident.resolution?.title ?? "Источник не сообщил выбранное действие.").font(.callout).textSelection(.enabled)
            } else {
                Text("Задача ждёт явного решения. Изменение модели или политики само по себе её не продолжает. Защита refs, config и .kaban остаётся обязательной.").font(.callout)
                if incident.kind.isKnown {
                    IncidentDecisionEditor(store: store, incident: incident)
                } else { Text("Неизвестный тип. Обновите Kaban перед выбором действия.").font(.callout).foregroundStyle(theme.secondary) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.status("incident").1.opacity(theme.dark ? 0.16 : 0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct IncidentDecisionEditor: View {
    @Bindable var store: BoardStore
    let incident: Incident
    private var decisions: IncidentDecisionStore { store.incidentDecisions }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft = decisions.draft(incident.id) {
                if draft.context != decisions.currentContext(incident.id) {
                    Text("Данные изменились. Проверьте инцидент перед отправкой.").font(.caption)
                    Button("Использовать актуальные данные") { decisions.useCurrent(incident.id) }.disabled(decisions.currentContext(incident.id) == nil || decisions.receipt(incident.id)?.isPending == true)
                }
                Picker("Вернуть на стадию", selection: Binding(get: { draft.target }, set: { decisions.edit(incident.id, target: $0) })) {
                    Text("Выберите стадию").tag(Optional<StageID>.none)
                    ForEach(draft.context.targets, id: \.id) { stage in Text(stage.name).tag(Optional(stage.id)) }
                }
                TextEditor(text: Binding(get: { decisions.draft(incident.id)?.comments ?? "" }, set: { decisions.edit(incident.id, comments: $0) }))
                    .frame(minHeight: 70, maxHeight: 100).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    .accessibilityLabel("Замечание агенту по инциденту")
                Text("Замечание попадёт в следующий prompt. После подтверждения backend инцидент станет разобранным, задача встанет в очередь выбранной стадии.").font(.caption)
                Button("Вернуть с замечанием") { Task { await decisions.submit(incident.id) } }
                    .buttonStyle(KabanButtonStyle(primary: true)).disabled(!decisions.canSubmit(incident.id)).id("incident-decision")
                if let receipt = decisions.receipt(incident.id) {
                    Text(receipt.isPending ? "Ждём подтверждающих событий…" : receipt.phase == .applied ? "Решение подтверждено событиями." : "Решение не применено. Замечание сохранено.").font(.caption)
                }
            } else { Text("Для возврата нужны актуальные детали и pipeline задачи от службы.").font(.caption) }
            if let error = decisions.storageError { Text(error).font(.caption) }
            if let card = store.projection?.tasks[incident.taskId], card.state == .waitingHuman(.incident) {
                HStack {
                    Button("Ужесточить политику…") {
                        store.openIncidentPolicy(incident.projectId)
                    }.disabled(store.projection?.projects[incident.projectId] == nil)
                    Button("Отменить…") { store.controlSheet = .init(store: store, card: card, action: .cancel) }
                        .disabled(!store.canControl(card, action: .cancel))
                }
                Text("Модель меняется в блоке «Модель задачи» ниже.").font(.caption)
            }
        }.disabled(decisions.receipt(incident.id)?.isPending == true)
    }
}

private extension IncidentKind {
    var title: String {
        switch self {
        case .refsMoved: "Изменены защищённые refs"
        case .tagsChanged: "Изменены теги"
        case .configChanged: "Изменён Git config"
        case .kabanDirChanged: "Изменена .kaban"
        case .foreignBase: "Посторонняя база ветки"
        default: "Неизвестное нарушение · \(rawValue)"
        }
    }
}
private extension IncidentResolution {
    var title: String {
        let action: String
        switch command {
        case "requestChanges": action = "Возврат с замечанием"
        case "answerHuman": action = "Замечание агенту"
        case "retryStage": action = "Повтор стадии"
        case "moveTask": action = "Перенос"
        case "cancelTask", "reject": action = "Отмена"
        default: action = command
        }
        return action + (target.map { " · \($0.rawValue)" } ?? "") + (keepBranch.map { $0 ? " · выбрано сохранение ветки" : " · выбрано удаление ветки" } ?? "")
    }
}
private extension Date {
    var incidentDate: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "Europe/Kaliningrad"); formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: self) + " · Калининград"
    }
}
