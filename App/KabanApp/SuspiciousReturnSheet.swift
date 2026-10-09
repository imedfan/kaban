import SwiftUI
import KabanProtocol
import KabanBoardCore

struct SuspiciousReturnSheet: View {
    @Bindable var store: BoardStore
    let route: SuspiciousReturnRoute
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var files: SuspiciousFilesStore { store.suspiciousFiles }
    private var draft: SuspiciousFilesStore.ReturnDraft? { files.draft(for: route.taskID) }
    private var accepts: Bool { draft?.comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true }
    private var pending: Bool { store.session.pending(in: .task(route.taskID)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Вернуть задачу", systemImage: "arrow.uturn.backward").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Закрыть") { store.suspiciousReturnRoute = nil }.keyboardShortcut(.cancelAction).buttonStyle(KabanButtonStyle(compact: true))
            }
            if let draft {
                Text(draft.context.card.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Куда", selection: Binding(get: { draft.target }, set: { if let target = $0 { files.edit(route.taskID, target: target) } })) {
                            Text("Выберите стадию").tag(StageID?.none)
                            ForEach(draft.context.targets, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }.disabled(pending)
                        Text("Только предыдущие стадии, которые правят код. Цель задана в pipeline для " + (draft.context.stage?.kind == .gate ? "провала проверки." : "конфликта слияния."))
                            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Всего возвратов \(draft.context.card.bounceByReason.values.reduce(0, +))/\(draft.context.bounceLimitTotal.map(String.init) ?? "лимит неизвестен"). Ручной возврат счётчики не меняет.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                        if let value = draft.context.stage?.kind == .gate ? draft.context.stage?.onFail : draft.context.stage?.onConflict {
                            Text("\(draft.context.card.stageId.rawValue) → \(value.stage.rawValue) · лимит \(value.limit)")
                                .font(.system(size: 11)).foregroundStyle(theme.secondary)
                        }
                        Text("Замечание агенту").font(.system(size: 12, weight: .medium))
                        TextEditor(text: Binding(get: { files.draft(for: route.taskID)?.comments ?? "" }, set: { files.edit(route.taskID, comments: $0) }))
                            .font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 90).padding(8)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: 7)).disabled(pending)
                            .accessibilityIdentifier("suspicious-return-comment")
                        Text("Пусто — файлы будут приняты. Напишите замечание, чтобы вернуть без принятия.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Подставить «Убери из ветки…»") { files.edit(route.taskID, comments: draft.context.removalText) }
                            .buttonStyle(KabanButtonStyle(compact: true)).disabled(pending)
                        ForEach(draft.context.files, id: \.path) { file in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Text(accepts ? "в принятые · " + String(file.blob.prefix(10)) : "останется помеченным")
                                    .font(.system(size: 11)).foregroundStyle(accepts ? Color.green : theme.status("waiting").2)
                            }
                        }
                        if draft.context != files.context(for: route.taskID), !pending {
                            Text("Задача или набор изменились. Ваш текст сохранён.").font(.system(size: 12)).foregroundStyle(.orange)
                            Button("Использовать текст для текущего набора") { files.useCurrent(route.taskID) }
                                .buttonStyle(KabanButtonStyle(compact: true)).disabled(files.context(for: route.taskID) == nil)
                        }
                        if let error = files.storageError { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
                        if let record = files.returnReceipt(for: route.taskID) {
                            if record.isPending { Text("Ожидаем подтверждение Kaban…").font(.system(size: 12)).foregroundStyle(theme.secondary) }
                            else if case .rejected(let failure) = record.phase { Text(failure.message).font(.system(size: 12)).foregroundStyle(.orange) }
                        }
                    }.padding(.trailing, 4)
                }
                Label(accepts ? "Набор принимается. Задача вернётся без замечания; изменённый файл сработает снова."
                      : "Набор не принимается. Агент получит замечание; файлы проверяются после его гейтов.",
                      systemImage: accepts ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(10)
                    .background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 8))
                Divider()
                HStack {
                    Text(draft.target.map { target in
                        "Возврат в " + (draft.context.targets.first { $0.id == target }?.name ?? target.rawValue)
                    } ?? "Выберите стадию возврата")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary)
                    Spacer()
                    Button(accepts ? "Принять файлы и вернуть" : "Вернуть с замечанием") { Task { await files.submitReturn(route.taskID) } }
                        .buttonStyle(KabanButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                        .disabled(!files.canReturn(route.taskID)).accessibilityIdentifier("suspicious-return-submit")
                }
            } else { Text("Для возврата нужны актуальные детали gate/merge и pipeline.").foregroundStyle(theme.secondary) }
        }.padding(20).frame(width: 620, height: 570).background(theme.window)
            .onChange(of: files.returnReceipt(for: route.taskID)?.phase) { _, phase in
                if phase == .applied { store.suspiciousReturnRoute = nil }
            }
    }
}
