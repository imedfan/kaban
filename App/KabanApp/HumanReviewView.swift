import SwiftUI
import KabanProtocol
import KabanBoardCore

struct HumanReviewRoute: Identifiable {
    let id = UUID()
    let taskID: TaskID
    let decision: HumanReviewDecision
}

struct HumanReviewNotice: View {
    @Bindable var store: BoardStore
    let taskID: TaskID
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    var body: some View {
        if store.humanReview.isStale(taskID), store.humanReview.receipt(for: taskID)?.isPending != true {
            VStack(alignment: .leading, spacing: 8) {
                Label("Результат или состояние изменились. Комментарий сохранён.", systemImage: "info.circle")
                if store.humanReview.currentContext(for: taskID) != nil {
                    Button("Проверил новый результат · продолжить ревью") { store.humanReview.useCurrentReview(taskID) }
                        .buttonStyle(KabanButtonStyle(compact: true)).disabled(store.session.detailReadState != .loaded)
                } else { Text("Решение доступно, когда задача снова будет на Human Review.").foregroundStyle(theme.secondary) }
            }.font(.system(size: 11)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.control, in: RoundedRectangle(cornerRadius: 9))
        }
        if let record = store.humanReview.receipt(for: taskID), let message = reviewReceiptMessage(record.phase) {
            Label(message, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        if let error = store.humanReview.storageError { Text(error).font(.system(size: 11)).foregroundStyle(theme.secondary) }
    }
}

func reviewReceiptMessage(_ phase: ClientCommandPhase) -> String? {
    switch phase {
    case .sending: "Отправляем решение…"
    case .deliveryUncertain: "Исход отправки неизвестен. Kaban проверит ту же команду после подключения; второе решение не нужно."
    case .awaitingEvent: "Решение принято службой. Ждём подтверждения в истории задачи."
    case .rejected(let error): "Решение не принято: " + error.message
    case .applied: "Решение подтверждено службой. Текущее состояние показано в шапке задачи."
    default: nil
    }
}

struct HumanReviewFooter: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    let edit: () -> Void
    let priority: () -> Void
    private var defaultTarget: StageID? {
        HumanReviewContext(detail: detail, pipeline: store.projection?.pipelines[detail.task.projectId])?.defaultTarget
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if defaultTarget == nil {
                HStack(alignment: .top, spacing: 8) {
                    Text("Некуда вернуть: нет стадии, которая правит код").fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Ошибки пайплайна…") { store.openPipelineIssues(detail.task.projectId) }.buttonStyle(.link)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Button("Cursor") { Task { await store.openClone(detail.clonePath) } }
                    .buttonStyle(KabanButtonStyle()).disabled(detail.clonePath == nil || store.openingClone || store.session.detailReadState != .loaded)
                    .fixedSize().accessibilityLabel("Открыть клон задачи в Cursor").help("Открыть клон задачи в Cursor")
                Button("Вернуть…") { store.beginReview(.requestChanges, task: detail.task.id) }
                    .buttonStyle(KabanButtonStyle()).disabled(defaultTarget == nil || !store.can(.requestChanges))
                    .help("Вернуть с комментарием в выбранную стадию")
                Button("Отклонить…") { store.beginReview(.reject, task: detail.task.id) }
                    .buttonStyle(KabanButtonStyle()).disabled(!store.can(.reject))
                Spacer(minLength: 0)
                if store.humanReview.receipt(for: detail.task.id)?.isPending == true { ProgressView().controlSize(.small) }
                Button("Одобрить") { Task { await store.humanReview.submit(.approve, for: detail.task.id) } }
                    .buttonStyle(KabanButtonStyle(primary: true)).disabled(!store.humanReview.canSubmit(.approve, for: detail.task.id))
                    .accessibilityIdentifier("review.approve").help("Одобрить результат · ⌘↩")
                Menu {
                    Button("Изменить…", action: edit).disabled(!store.can(.editTask) || store.session.detailReadState != .loaded)
                    Button("Приоритет · \(detail.task.priority)…", action: priority).disabled(!store.can(.setPriority))
                    TaskControlMenu(store: store, card: detail.task)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Другие действия задачи")
            }.disabled(store.session.pending(in: .task(detail.task.id)) != nil)
        }
    }
}

struct HumanReviewSheet: View {
    @Bindable var store: BoardStore
    let route: HumanReviewRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var theme: ReferenceTheme { .init(dark: scheme == .dark) }
    private var review: HumanReviewStore { store.humanReview }
    private var draft: HumanReviewStore.Draft? { review.draft(for: route.taskID) }
    private var pending: Bool { review.receipt(for: route.taskID)?.isPending == true }
    private var changes: Bool { route.decision == .requestChanges }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: changes ? "arrow.uturn.backward" : "xmark.circle").font(.system(size: 22))
                    .foregroundStyle(theme.accent).frame(width: 42, height: 42).background(theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(changes ? "Вернуть с комментарием" : "Отклонить результат").font(.system(size: 18, weight: .semibold))
                    Text(route.taskID.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).lineLimit(1).help(route.taskID.rawValue)
                }
                Spacer(); KabanIconButton(symbol: "xmark", help: "Закрыть · Esc") { dismiss() }
            }
            if let draft { Text(draft.context.card.title).font(.system(size: 13, weight: .medium)).lineLimit(2).help(draft.context.card.title) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HumanReviewNotice(store: store, taskID: route.taskID)
                    if let draft {
                        if !changes {
                            Picker("Решение", selection: Binding(get: { draft.cancel }, set: { review.edit(route.taskID, cancel: $0) })) {
                                Text("Отменить задачу").tag(true)
                                Text("Вернуть в стадию без комментария").tag(false)
                            }.pickerStyle(.radioGroup).disabled(pending || review.isStale(route.taskID))
                        }
                        if changes || !draft.cancel {
                            targetPicker(draft)
                            Text("Ручной возврат не увеличивает счётчики возвратов. Задача получит приоритет и пройдёт стадии и Human Review снова.")
                                .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if changes {
                            Text("Комментарий агенту").font(.system(size: 12, weight: .semibold))
                            TextEditor(text: Binding(get: { review.draft(for: route.taskID)?.comments ?? "" }, set: { review.edit(route.taskID, comments: $0) }))
                                .font(.system(size: 12)).scrollContentBackground(.hidden).padding(8).frame(height: 136)
                                .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.strongLine, lineWidth: 0.5))
                                .disabled(pending || review.currentContext(for: route.taskID) == nil)
                                .accessibilityLabel("Комментарий к возврату").accessibilityIdentifier("review.comments")
                            Text("Комментарий обязателен. Текст сохранится при закрытии окна или отказе службы.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                        } else if draft.cancel {
                            Toggle("Сохранить ветку", isOn: Binding(get: { draft.keepBranch }, set: { review.edit(route.taskID, keepBranch: $0) }))
                                .disabled(pending || review.isStale(route.taskID)).accessibilityIdentifier("review.keepBranch")
                            Text("Задача станет отменённой, клон будет удалён после обработки отмены. С галочкой последний коммит ветки сохранится в репозитории проекта:")
                                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Text("refs/kaban/archive/" + route.taskID.rawValue).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            Text("Незакоммиченные правки не входят в сохранённую ветку.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                        }
                    }
                    if !store.can(name) { Text(store.unavailableReason(name)).font(.system(size: 11)).foregroundStyle(theme.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 3)
            }.frame(maxHeight: changes ? 350 : 300)
            Divider()
            HStack {
                Button("Закрыть") { dismiss() }.buttonStyle(KabanButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if pending { ProgressView().controlSize(.small) }
                Button(pending ? "Ждём подтверждения…" : changes ? "Вернуть с комментарием" : "Отклонить") {
                    Task { await review.submit(route.decision, for: route.taskID) }
                }.buttonStyle(KabanButtonStyle(primary: true)).disabled(!review.canSubmit(route.decision, for: route.taskID))
                    .accessibilityIdentifier("review.confirm")
            }
        }.padding(20).frame(width: 560).background(theme.window).foregroundStyle(theme.text)
            .onChange(of: review.receipt(for: route.taskID)?.phase) { _, phase in if phase == .applied { dismiss() } }
    }
    private var name: CommandName { changes ? .requestChanges : .reject }
    @ViewBuilder private func targetPicker(_ draft: HumanReviewStore.Draft) -> some View {
        if changes && draft.context.defaultTarget == nil {
            Text("Некуда вернуть: нет стадии, которая правит код").font(.system(size: 11)).foregroundStyle(theme.secondary)
            Button("Ошибки пайплайна…") { store.openPipelineIssues(draft.context.card.projectId) }.buttonStyle(.link)
        } else {
            Picker("Куда", selection: Binding(get: { draft.target }, set: { if let id = $0 { review.edit(route.taskID, target: id) } })) {
                Text("Выберите стадию").tag(StageID?.none)
                ForEach(draft.context.targets, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(pending || review.isStale(route.taskID)).accessibilityIdentifier("review.target")
            Text("Только предшествующие стадии, которые правят код.").font(.system(size: 11)).foregroundStyle(theme.secondary)
        }
    }
}
