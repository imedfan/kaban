import SwiftUI
import KabanProtocol
import KabanBoardCore

struct MacSettingsView: View {
    @Bindable var store: BoardStore
    let theme: ReferenceTheme
    private var editor: MacSettingsStore { store.macSettings }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Настройки этого Мака", systemImage: "cpu").font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button("Отменить изменения") { editor.reset() }.disabled(editor.pending)
                }
                Text("Хранятся у службы Kaban на этом Маке.").font(.callout).foregroundStyle(theme.secondary)
                SchedulerFlagsView(store: store, theme: theme)
                ceiling
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) { quotaOptions; QuotaBarsView(store: store, theme: theme) }.frame(width: 350)
                    ModelSettingsView(store: store.models, theme: theme).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                projects
                if let error = editor.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if let phase = editor.receipt?.phase {
                    Text(phase == .applied ? "Подтверждено службой" : editor.receipt?.isPending == true ? "Ожидаем подтверждения событиями…" : "Изменение не применено. Ввод сохранён.")
                        .font(.callout).foregroundStyle(theme.secondary)
                }
            }.padding(20).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.task { editor.begin(); editor.observeOutcome() }
            .onChange(of: store.session.pendingRecords) { _, _ in editor.observeOutcome() }
            .onChange(of: store.projection?.settings) { _, _ in editor.begin(); editor.observeOutcome() }
    }
    private var ceiling: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Агенты и потолок", systemImage: "cpu").font(.headline)
            HStack {
                Text("Максимум одновременных запусков")
                TextField("Целое число", text: Binding(get: { editor.ceiling }, set: editor.editCeiling)).textFieldStyle(.roundedBorder).frame(width: 90)
                    .disabled(editor.pending).accessibilityIdentifier("mac.ceiling")
                Button("Сохранить потолок") { Task { await editor.submit(.ceiling) } }.disabled(!editor.canSubmit(.ceiling))
            }
            Text("Сейчас: \(editor.settings.map { String($0.maxConcurrentRuns) } ?? "нет данных") · резервирований: \(store.reservationCount). Подтверждённые процессы служба не сообщает.")
                .font(.caption).foregroundStyle(theme.secondary)
            Text("Снижение потолка и пауза Мака/проекта останавливают новые старты. Текущие запуски продолжаются.")
                .font(.callout).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            Button(store.macPaused ? "Продолжить новые запуски" : "Пауза новых запусков") { Task { await store.toggleMacPause() } }
                .disabled(!store.can(store.macPaused ? .resumeAll : .pauseAll) || editor.pending)
            staleNotice(.ceiling)
        }.padding(18).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private var quotaOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Квота Cursor · неофициально", systemImage: "gauge.with.dots.needle.50percent").font(.headline)
            if let options = editor.options {
                Toggle("Получать квоту Cursor", isOn: Binding(get: { options.enabled }, set: { value in var changed = options; changed.enabled = value; editor.editOptions(changed) }))
                    .disabled(editor.pending).accessibilityIdentifier("mac.quota.enabled")
                Text("Опция требует отдельного согласия. Предполагается только чтение токена Cursor на этом Маке и запрос статистики к api2.cursor.sh. Токен не вводится и не хранится в этой форме.")
                    .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Понимаю и соглашаюсь", isOn: Binding(get: { options.consent }, set: { value in var changed = options; changed.consent = value; if !value { changed.enabled = false }; editor.editOptions(changed) }))
                    .toggleStyle(.checkbox).disabled(editor.pending).accessibilityIdentifier("mac.quota.consent")
                if let date = editor.settings?.quotaConsentedAt {
                    Text("Согласие подтверждено: " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(theme.secondary)
                    Button("Отозвать согласие") { var changed = options; changed.enabled = false; changed.consent = false; editor.editOptions(changed); Task { await editor.submit(.quota) } }
                        .disabled(editor.pending || editor.stale(.quota) || !store.can(.setQuotaOptions))
                }
                Picker("Интервал", selection: Binding(get: { ["60", "300", "900", "1800"].contains(editor.interval) ? editor.interval : "custom" }, set: { if $0 != "custom" { editor.editInterval($0) } else { editor.editInterval("") } })) {
                    Text("1 мин").tag("60"); Text("5 мин").tag("300"); Text("15 мин").tag("900"); Text("30 мин").tag("1800"); Text("Свой").tag("custom")
                }.pickerStyle(.segmented).disabled(editor.pending)
                HStack { Text("Интервал, секунд"); TextField("Положительное целое", text: Binding(get: { editor.interval }, set: editor.editInterval)).textFieldStyle(.roundedBorder).disabled(editor.pending) }
                ForEach([ModelPool.cm, .om], id: \.self) { pool in
                    HStack {
                        Text("Порог остатка " + pool.rawValue.capitalized).font(.caption)
                        Slider(value: Binding(get: { pool == .cm ? options.thresholdCm : options.thresholdOm }, set: { var changed = options; if pool == .cm { changed.thresholdCm = $0 } else { changed.thresholdOm = $0 }; editor.editOptions(changed) }), in: 0...100, step: 1).disabled(editor.pending)
                        Text("\(Int(pool == .cm ? options.thresholdCm : options.thresholdOm))%").monospacedDigit().frame(width: 42)
                    }
                }
                Button("Применить квоту") { Task { await editor.submit(.quota) } }.disabled(!editor.canSubmit(.quota)).accessibilityIdentifier("mac.quota.apply")
                staleNotice(.quota)
            } else { Text("Настройки неизвестны. Подключите актуальную службу Kaban.").foregroundStyle(theme.secondary) }
            Text("Служба пока не сообщает состояние опроса Cursor. Включение настройки не подтверждает получение данных. Ограничения по ответам Cursor продолжают действовать.")
                .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
    @ViewBuilder private func staleNotice(_ section: MacSettingsStore.Section) -> some View {
        if editor.settings != nil && editor.stale(section) {
            Text("Настройки изменились в другом клиенте. Ввод сохранён.").font(.caption).foregroundStyle(.orange)
            Button("Использовать актуальные данные") { editor.useCurrent() }.disabled(editor.pending)
        }
    }
    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Проекты и веса", systemImage: "square.stack").font(.headline)
            ForEach(store.projection?.projectOrder ?? [], id: \.self) { id in
                if let project = store.projection?.projects[id] {
                    HStack {
                        Text(project.name).lineLimit(1).help(project.name)
                        Spacer()
                        Text("Вес \(project.weight) · максимум \(project.maxRuns.map(String.init) ?? "общий")").font(.caption)
                        Button(store.projectPaused(id) ? "Продолжить" : "Пауза") { Task { await store.toggleProjectPause(id) } }
                            .disabled(!store.can(store.projectPaused(id) ? .resumeProject : .pauseProject) || store.session.pending(in: .project(id)) != nil)
                        Button("Настроить") { store.settings(for: id).begin(.resources); store.screen = .project(id) }
                    }
                }
            }
        }.padding(18).background(theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QuotaBarsView: View {
    let store: BoardStore
    let theme: ReferenceTheme
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                if !compact { Text("Расход по пулам").font(.headline) }
                ForEach([ModelPool.cm, .om], id: \.self) { pool in
                    let view = QuotaPresentation(pool: pool, quota: store.projection?.ephemeral.quota,
                                                 options: store.projection?.settings?.quotaOptions,
                                                 flags: store.projection?.ephemeral.schedulerFlags ?? [], now: context.date)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(pool.rawValue.capitalized).font(.caption.bold()).frame(width: 24, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.control)
                                    if let percent = view.percent {
                                        Capsule().fill(pool == .cm ? theme.accent : theme.status("waiting").0).frame(width: geometry.size.width * percent / 100)
                                        if let fraction = view.cycleFraction { Rectangle().fill(theme.text).frame(width: 2).offset(x: max(0, geometry.size.width * fraction - 1)) }
                                        if let threshold = view.thresholdUsed { Rectangle().fill(theme.status("waiting").0).frame(width: 1).offset(x: max(0, geometry.size.width * threshold / 100 - 1)) }
                                    }
                                }
                            }.frame(height: 8).accessibilityHidden(true)
                            Text(view.percent.map { "\(Int($0))%" } ?? "—").font(.caption).monospacedDigit()
                        }
                        if view.percent == nil || view.message == "Исчерпан" { Text(view.message).font(.caption).foregroundStyle(theme.secondary) }
                        if !compact, let reset = view.resetAt { Text("Сброс: " + reset.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(theme.secondary) }
                    }.accessibilityElement(children: .combine)
                }
                if !compact {
                    Text("Чёрточка — доля календарного цикла, цветная метка — порог остатка.").font(.caption).foregroundStyle(theme.secondary)
                    if let date = store.projection?.ephemeral.quota?.fetchedAt {
                        Text("Данные источника: " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(theme.secondary)
                    }
                }
            }
        }
    }
}

struct SchedulerFlagsView: View {
    @Bindable var store: BoardStore
    let theme: ReferenceTheme
    var project: ProjectID?
    private var flags: [SchedulerFlag] {
        (store.projection?.ephemeral.schedulerFlags ?? []).filter {
            let id = SchedulerFlagPresentation($0).project
            return project == nil ? id == nil : id == project
        }.sorted { SchedulerFlagPresentation.priority($0) < SchedulerFlagPresentation.priority($1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(flags, id: \.self) { flag in
                let row = SchedulerFlagPresentation(flag)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: flag == .macPaused ? "pause.circle" : "exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) { Text(row.title).font(.callout.bold()); Text(row.detail).font(.caption).foregroundStyle(theme.secondary).textSelection(.enabled) }
                    Spacer(minLength: 0)
                    if let action = row.action, let command = row.command {
                        Button(action) { Task { await store.models.send(command) } }.disabled(!store.models.can(command) || !supportsScope(command))
                    }
                    if let project = row.project { Button("Настройки") { store.screen = .project(project) } }
                }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if project == nil {
                ForEach(store.models.flags, id: \.modelId) { flag in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(flag.requested + (flag.reason == .unavailable ? " недоступна" : " подменяется Cursor")).font(.callout.bold())
                            if let fallback = flag.fallbackModel { Text("Cursor сообщает: " + fallback).font(.caption) }
                        }
                        Spacer()
                        Button("Модели") { store.screen = .quota }
                        Button("Снять флаг") { Task { await store.models.send(.clearModelFlag(modelId: flag.modelId)) } }.disabled(!store.models.can(.clearModelFlag(modelId: flag.modelId)))
                    }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private func supportsScope(_ command: Command) -> Bool {
        guard case .recheck(let scope) = command else { return true }
        let name = scope == .runner ? "runner" : "project"
        return store.capabilities?.commands.first { $0.name == CommandName.recheck.rawValue }?.scopes?.contains(name) == true
    }
}
