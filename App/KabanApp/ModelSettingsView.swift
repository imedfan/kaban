import SwiftUI
import KabanProtocol
import KabanBoardCore

struct ModelSettingsView: View {
    @Bindable var store: ModelSettingsStore
    let theme: KabanTheme
    @State private var query = ""
    @State private var expandedFamilies: Set<String> = ["Composer"]
    @State private var reviewOnly = false
    @State private var poolFilter = "Все"
    @State private var pattern = ""
    @State private var pool = ModelPool.om
    private var models: [ModelInfo] {
        store.catalog.filter { !$0.forbidden && $0.id.rawValue.lowercased() != "auto" && (!reviewOnly || $0.needsReview)
            && (poolFilter == "Все" || ($0.pool == .cm ? "Cm" : "Om") == poolFilter)
            && (query.isEmpty || ($0.id.rawValue + " " + $0.name).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Модели → пулы", systemImage: "square.stack.3d.up").font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.receipt?.isPending == true || store.reading { ProgressView().controlSize(.small) }
                Button("Обновить каталог") { Task { await store.send(.refreshModelCatalog) } }
                    .buttonStyle(KabanButtonStyle(compact: true)).disabled(!store.can(.refreshModelCatalog)).accessibilityIdentifier("models-refresh")
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let phase = store.receipt?.phase {
                Text(phase == .applied ? "Изменение подтверждено службой Kaban" : store.receipt?.isPending == true ? "Ожидаем подтверждение службы Kaban…" : "Команда завершилась; проверьте результат")
                    .font(.caption).foregroundStyle(theme.secondary)
            }
            Text("Правила применяются службой Kaban. Пользовательские исключения имеют приоритет.").font(.caption).foregroundStyle(theme.secondary)
            if let rules = store.rules {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    HStack(spacing: 10) {
                        Text(rule.pattern).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4); ModelPoolBadge(pool: rule.pool)
                        if rule.source == .builtin { Label("Встроено", systemImage: "lock").font(.caption).foregroundStyle(theme.secondary) }
                        else {
                            Button("Убрать") { Task { await store.send(.removeModelPoolRule(pattern: rule.pattern)) } }
                                .disabled(!store.can(.removeModelPoolRule(pattern: rule.pattern)))
                        }
                    }.padding(.vertical, 4)
                }
                HStack {
                    TextField("ID или префикс-*", text: $pattern).textFieldStyle(.roundedBorder).accessibilityIdentifier("model-pool-pattern")
                    Picker("Пул", selection: $pool) { Text("Cm").tag(ModelPool.cm); Text("Om").tag(ModelPool.om) }.frame(width: 90)
                    Button("Сохранить правило") { Task { await store.send(.setModelPoolRule(pattern: pattern, pool: pool)) } }
                        .fixedSize()
                        .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.can(.setModelPoolRule(pattern: pattern, pool: pool)))
                }
            } else { Text("Служба не передала сохранённые правила. Обновите службу Kaban.").font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack {
                Picker("Показать", selection: $poolFilter) { Text("Все \(store.catalog.count)").tag("Все"); Text("Cm").tag("Cm"); Text("Om").tag("Om") }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
                Toggle("Проверь пул · \(store.catalog.filter(\.needsReview).count)", isOn: $reviewOnly).toggleStyle(.checkbox)
                Spacer(minLength: 0)
            }
            TextField("Поиск модели", text: $query).textFieldStyle(.roundedBorder)
            if !store.catalogKnown { Text("Каталог пока неизвестен. После подключения появятся сохранённые данные.").font(.caption) }
            else if models.isEmpty { Text(store.catalog.isEmpty ? "Сохранённый каталог пуст. Обновите его через Cursor CLI." : "Нет моделей с такими условиями.").font(.caption).foregroundStyle(theme.secondary) }
            ForEach(Array(Set(models.map(ModelSelection.family))).sorted(), id: \.self) { family in
                DisclosureGroup("\(family) · \(models.filter { ModelSelection.family($0) == family }.count)", isExpanded: Binding(get: { expandedFamilies.contains(family) }, set: { if $0 { expandedFamilies.insert(family) } else { expandedFamilies.remove(family) } })) {
                    ForEach(models.filter { ModelSelection.family($0) == family }, id: \.id) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            ModelCatalogRow(model: model, flags: store.flags)
                            if model.needsReview {
                                HStack { Text("Назначить пул:").font(.caption); poolButton(model, .cm); poolButton(model, .om) }
                            }
                        }.padding(.vertical, 6)
                    }
                }.font(.system(size: 12)).padding(8).background(theme.control.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Новая модель без привязки получает «проверь пул». Её текущий пул приходит из backend. Снятие флага не гарантирует успешный следующий запуск.")
                .font(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(theme.card, in: RoundedRectangle(cornerRadius: 12)).task { await store.loadIfNeeded(); if AppArguments.qaValue("--model-live-smoke") != nil { expandedFamilies = Set(store.catalog.map(ModelSelection.family)) } }
    }
    private func poolButton(_ model: ModelInfo, _ pool: ModelPool) -> some View {
        Button(pool == .cm ? "Cm" : "Om") { Task { await store.send(.setModelPoolRule(pattern: model.id.rawValue, pool: pool)) } }
            .disabled(store.rules == nil || !store.can(.setModelPoolRule(pattern: model.id.rawValue, pool: pool)))
    }
}
