import SwiftUI
import KabanProtocol
import KabanBoardCore

/// One composer above the task materials, using the inspector's native tokens.
struct HumanAnswerView: View {
    @Bindable var store: BoardStore
    let card: TaskCard
    @Environment(\.colorScheme) private var scheme
    private var theme: KabanTheme { .init(dark: scheme == .dark) }
    private var answers: HumanAnswerStore { store.humanAnswers }
    private var draft: HumanAnswerStore.Draft? { answers.draft(for: card.id) }
    private var receipt: ClientCommandJournal.Record? { answers.receipt(for: card.id) }
    private var pending: Bool { receipt?.isPending == true }
    var body: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 10) {
                Label(draft.context.request == nil ? "Замечание агенту" : "Вопрос агента", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                if let request = draft.context.request {
                    question(request, prefix: "")
                }
                if answers.isStale(card.id), !pending {
                    Label("Ожидание изменилось. Ваш текст сохранён.", systemImage: "info.circle").font(.system(size: 12, weight: .medium))
                    if let current = answers.currentContext(for: card.id) {
                        if let request = current.request { question(request, prefix: "Текущий вопрос: ") }
                        else { Text("Теперь задача ждёт замечания агенту.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                        Button("Использовать текст для текущего ожидания") { answers.useTextForCurrentContext(card.id) }
                            .buttonStyle(KabanButtonStyle(compact: true))
                            .disabled(store.session.detailReadState != .loaded || !store.can(.answerHuman))
                    } else { Text(unavailableText).font(.system(size: 11)).foregroundStyle(theme.secondary) }
                }
                if let message = stateMessage {
                    Label(message, systemImage: "info.circle").font(.system(size: 11))
                        .foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text("Ответ вернёт задачу в очередь этой стадии с приоритетом ответа и сбросит общий счётчик запусков. Если попытки исчерпаны, служба добавит одну.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                Text(draft.context.request == nil ? "Замечание" : "Ваш ответ").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                TextEditor(text: Binding(get: { answers.draft(for: card.id)?.text ?? "" }, set: { answers.setText($0, for: card.id) }))
                    .font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(7).frame(height: 94).background(theme.card, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.strongLine, lineWidth: 0.5))
                    .disabled(pending || answers.currentContext(for: card.id) == nil)
                    .accessibilityLabel(draft.context.request == nil ? "Замечание агенту" : "Ответ на вопрос агента")
                    .accessibilityIdentifier("human.answer.text")
                if draft.context.card.state == .waitingHuman(.suspiciousFiles) {
                    Text("Набор файлов не будет принят. Агент получит новый запуск с замечанием; после гейтов проверка файлов повторится.")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !store.can(.answerHuman) { Text(store.unavailableReason(.answerHuman)).font(.system(size: 11)).foregroundStyle(theme.secondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.status("waiting").1, in: RoundedRectangle(cornerRadius: 10))
        } else if case .waitingHuman = card.state {
            Label(unavailableText, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if card.state == .running || card.state == .gating {
            Text("Ответ и замечание станут доступны, когда агент будет ждать человека. Для текущего запуска доступны действия задачи.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if receipt?.phase == .applied, answers.record(for: card.id)?.context.card.state == .waitingHuman(.suspiciousFiles) {
            Text("Замечание отправлено без принятия файлов. Проверка повторится после нового запуска агента.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let error = answers.storageError { Text(error).font(.system(size: 11)).foregroundStyle(theme.secondary) }
    }
    @ViewBuilder private func question(_ request: HumanRequest, prefix: String) -> some View {
        let long = request.question.count > 180 || request.question.components(separatedBy: .newlines).count > 3
        Text(prefix + request.question).font(.system(size: 12)).textSelection(.enabled)
            .lineLimit(long ? 4 : nil).fixedSize(horizontal: false, vertical: true)
        if long {
            Button("Полный вопрос…") {
                store.materialTextRoute = .init(id: request.requestId.rawValue, title: "Полный вопрос агента", text: request.question)
            }.buttonStyle(.link).font(.system(size: 11))
        }
        if let id = request.runId {
            if let run = store.detail?.runs.first(where: { $0.id == id }) {
                Button("Лог · запуск №\(run.number)") { store.logRunRoute = run }.font(.system(size: 11)).buttonStyle(.link)
            } else {
                Text("Запуск: " + id.rawValue + " · сведения ещё недоступны")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.faint).textSelection(.enabled)
            }
        }
    }
    private var stateMessage: String? {
        switch receipt?.phase {
        case .rejected(let failure): "Ответ не принят: " + failure.message
        case .deliveryUncertain: "Исход отправки неизвестен. Kaban проверит ту же команду после подключения; повторный ответ не нужен."
        case .awaitingEvent: "Служба приняла команду. Ждём подтверждения в истории задачи."
        default: nil
        }
    }
    private var unavailableText: String {
        let kind = store.projection?.pipelines[card.projectId]?.stages.first { $0.id == card.stageId }?.kind
        switch kind {
        case .human: return "На этой стадии нужно решение Human Review. Ответ агенту здесь недоступен."
        case .gate, .merge: return "Здесь нет агента. Используйте действия повтора или возврата задачи."
        case .agent: return "Актуальный вопрос недоступен. Обновите детали перед ответом; сохранённый текст останется в черновике."
        default: return "Ответ доступен только в ожидании человека на стадии агента."
        }
    }
}

struct HumanAnswerSubmitButton: View {
    @Bindable var store: BoardStore
    let taskID: TaskID
    private var receipt: ClientCommandJournal.Record? { store.humanAnswers.receipt(for: taskID) }
    var body: some View {
        HStack(spacing: 7) {
            if receipt?.isPending == true { ProgressView().controlSize(.small) }
            Button(title) { Task { await store.humanAnswers.submit(taskID) } }
                .buttonStyle(KabanButtonStyle(primary: true)).disabled(!store.humanAnswers.canSubmit(taskID))
                .accessibilityIdentifier("human.answer.submit").help("Отправить и продолжить · ⌘↩")
        }
    }
    private var title: String {
        switch receipt?.phase {
        case .sending: "Отправляем…"
        case .deliveryUncertain: "Проверяем отправку…"
        case .awaitingEvent: "Ждём подтверждения…"
        default: "Отправить и продолжить"
        }
    }
}
