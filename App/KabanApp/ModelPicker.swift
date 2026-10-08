import SwiftUI
import KabanProtocol
import KabanBoardCore

struct ModelPicker: View {
    @Bindable var store: ModelSettingsStore
    @Binding var selection: String
    let theme: ReferenceTheme
    @State private var open = false
    @State private var query = ""
    private var current: ModelInfo? { store.catalog.first { $0.id.rawValue == selection } }
    private var models: [ModelInfo] {
        store.catalog.filter { !$0.forbidden && $0.id.rawValue.lowercased() != "auto" &&
            (query.isEmpty || ($0.id.rawValue + " " + $0.name + " " + ModelSelection.family($0)).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                    Text(selection.isEmpty ? "Выберите явную модель…" : selection).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                    Spacer(minLength: 8)
                    if let current { ModelPoolBadge(pool: current.pool) }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }.padding(10).background(theme.control, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityIdentifier("model-picker").accessibilityLabel("Выбор явной модели")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Модель для следующего запуска").font(.headline)
                            Spacer()
                            Button { Task { await store.send(.refreshModelCatalog) } } label: { Image(systemName: "arrow.clockwise") }
                                .disabled(!store.can(.refreshModelCatalog)).help("Обновить каталог Cursor CLI")
                        }
                        TextField("Найти ID, имя или семейство", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("model-search")
                        if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        if !store.catalogKnown { Text("Каталог пока неизвестен. Подключитесь к службе Kaban.").font(.callout) }
                        else if models.isEmpty { Text(query.isEmpty ? "В сохранённом каталоге нет моделей." : "Модели не найдены.").font(.callout) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(Set(models.map(ModelSelection.family))).sorted(), id: \.self) { family in
                                    Text(family).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
                                    ForEach(models.filter { ModelSelection.family($0) == family }, id: \.id) { model in
                                        modelButton(model)
                                    }
                                }
                            }
                        }.frame(maxHeight: 300)
                        Text("Выбор только явный. Пул назначает служба Kaban; модель автоматически не меняется.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(width: 450).task { await store.loadIfNeeded() }
                }
            if !selection.isEmpty, current == nil {
                Text(store.catalogKnown ? "ID отсутствует в каталоге: \(selection). Текущее значение сохранено." : "Текущий ID: \(selection) · каталог ещё не получен.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let current, !ModelSelection.selectable(current, flags: store.flags) {
                Text("Модель недоступна. Текущий ID сохранён; выберите другую модель.").font(.caption).foregroundStyle(.orange)
            }
        }.task { await store.loadIfNeeded(); if BoardQA.argument("--qa-model-picker") == "yes" { query = BoardQA.argument("--qa-model-query") ?? ""; open = true } }
    }
    private func modelButton(_ model: ModelInfo) -> some View {
        Button {
            guard ModelSelection.selectable(model, flags: store.flags) else { return }
            selection = model.id.rawValue; open = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection == model.id.rawValue ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor)
                ModelCatalogRow(model: model, flags: store.flags)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).disabled(!ModelSelection.selectable(model, flags: store.flags))
            .accessibilityIdentifier("model-choice-" + model.id.rawValue)
    }

}

struct ModelPoolBadge: View {
    let pool: ModelPool
    var body: some View {
        Text(pool == .cm ? "Cm" : "Om").font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2).foregroundStyle(pool == .cm ? .purple : .teal)
            .background((pool == .cm ? Color.purple : Color.teal).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
struct ModelCatalogRow: View {
    let model: ModelInfo
    let flags: [ModelFlag]
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.id.rawValue).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(model.name).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !ModelSelection.selectable(model, flags: flags) { Text("недоступна").font(.caption2).foregroundStyle(.orange) }
            if flags.contains(where: { $0.modelId == model.id && $0.reason == .substituted }) { Text("подмена").font(.caption2).foregroundStyle(.orange) }
            if model.needsReview { Text("проверь пул").font(.caption2).foregroundStyle(.orange) }
            ModelPoolBadge(pool: model.pool)
        }
    }
}
