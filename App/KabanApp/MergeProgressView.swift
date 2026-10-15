import SwiftUI
import KabanProtocol
import KabanBoardCore

struct OverlapRoute: Identifiable { let task: TaskID; var id: String { task.rawValue } }

struct MergeBlockNotice: View {
    @Bindable var store: BoardStore
    let project: ProjectID
    @Environment(\.colorScheme) private var scheme
    private var theme: KabanTheme { .init(dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Слияние ждёт: в main есть ваши правки", systemImage: "lock")
                .font(.system(size: 12, weight: .semibold))
            Text("Они пересекаются с входящими изменениями. Завершите работу с этими правками, затем проверьте проект снова.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Проверить снова") { Task { await store.recheckProject(project) } }
                    .buttonStyle(KabanButtonStyle(compact: true)).disabled(!store.canRecheck(project))
                    .accessibilityIdentifier("merge.recheck")
                if let pending = store.pendingLabel(.project(project)) { Text(pending).font(.system(size: 11)).foregroundStyle(theme.secondary) }
            }
            if let record = store.recheckRecord(project) {
                if case .rejected(let failure) = record.phase { Text(failure.message).font(.system(size: 11)).foregroundStyle(theme.secondary).textSelection(.enabled) }
                if record.phase == .applied { Text("Проверка проекта подтверждена. Причина ожидания обновляется службой.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.control, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MergeProgressView: View {
    @Bindable var store: BoardStore
    let detail: TaskDetail
    @Environment(\.colorScheme) private var scheme
    private var theme: KabanTheme { .init(dark: scheme == .dark) }
    private var card: TaskCard { detail.task }
    private var pipeline: PipelineSummary? { store.projection?.pipelines[card.projectId] }
    private var stage: StageSummary? { pipeline?.stages.first { $0.id == card.stageId } }
    private var isMerge: Bool { stage?.kind == .merge }
    private var conflictCount: Int? { ReviewMaterialPresentation.conflictCount(card) }
    private var lastMergeIssue: String? { detail.artifacts.last { ["merge_conflict", "merge_gate_output"].contains($0.kind) }?.kind }
    var body: some View {
        if isMerge || conflictCount != nil || card.state == .done {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: card.state == .done ? "checkmark.circle" : "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.status(card.state == .done ? "done" : card.state == .waitingHuman(.conflictLimit) ? "waiting" : conflictCount != nil ? "conflict" : "merge").2)
                if card.state == .done {
                    if let result = MergePresentation.result(detail) {
                        Text("Результат подтверждён в локальной основной ветке.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                        Text(result.ref).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Text(result.commit).font(.system(size: 10, design: .monospaced)).lineLimit(2).textSelection(.enabled).help(result.commit)
                        Button("Скопировать commit") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.commit, forType: .string) }
                            .buttonStyle(.link).font(.system(size: 11))
                    } else { Text("Завершение подтверждено службой. Итоговый commit и ref не переданы.").font(.system(size: 11)).foregroundStyle(theme.secondary) }
                } else if isMerge {
                    if card.state == .blocked(.mainDirty) { MergeBlockNotice(store: store, project: card.projectId) }
                    else if card.state.status == .queued {
                        let queue = store.mergeQueue(card.projectId)
                        Text(MergePresentation.position(card.id, queue: queue).map { "Место \($0) из \(queue.count) · по порядку одобрения" } ?? "Порядок очереди не передан службой")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                        Text("Задачи проекта сливаются по одной. Завершение появится после подтверждённого обновления основной ветки.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if card.state == .gating {
                        Text("Служба выполняет rebase и повторные проверки. Результат локального слияния ещё не подтверждён.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if card.state == .waitingHuman(.conflictLimit) {
                        Text(LimitReasonText(card: card, pipeline: pipeline).qualifier ?? "Лимит возвратов при конфликте")
                            .font(.system(size: 11)).foregroundStyle(theme.status("waiting").2)
                        Text("Автоматический возврат остановлен на стадии слияния. Откройте материалы и верните задачу агенту с комментарием.")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Вернуть с комментарием…") { store.beginReview(.requestChanges, task: card.id) }
                            .buttonStyle(KabanButtonStyle(compact: true))
                            .disabled(store.humanReview.currentContext(for: card.id)?.defaultTarget == nil || !store.can(.requestChanges) || store.session.pending(in: .task(card.id)) != nil)
                        if store.humanReview.currentContext(for: card.id)?.defaultTarget == nil {
                            Button("Проверить ошибки пайплайна…") { store.openPipelineIssues(card.projectId) }.buttonStyle(.link)
                        }
                    }
                } else if conflictCount != nil {
                    Text("После возврата задача проходит исправление и Human Review заново. Текущая стадия: \(stage?.name ?? card.stageId.rawValue).")
                        .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if conflictCount != nil, card.state != .done {
                    HStack {
                        Button("Материалы слияния") { store.detailTab = "Сводка" }.buttonStyle(.link)
                        Button("Замечания и события") { store.detailTab = "Лента" }.buttonStyle(.link)
                    }.font(.system(size: 11))
                }
                if !card.overlapsWith.isEmpty {
                    Button("Пересечения · \(card.overlapsWith.count)") { store.overlapRoute = .init(task: card.id) }.buttonStyle(.link)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 0.5))
        }
    }
    private var title: String {
        if card.state == .done { return "Задача завершена" }
        if card.state == .waitingHuman(.conflictLimit) { return "Лимит возвратов" }
        if !isMerge {
            let reason = lastMergeIssue == "merge_conflict" ? "После конфликта" : lastMergeIssue == "merge_gate_output" ? "После проверки слияния" : "После возврата из слияния"
            return reason + " · возвратов \(conflictCount ?? 0)"
        }
        return "Локальное слияние"
    }
}

struct OverlapSheet: View {
    @Bindable var store: BoardStore
    let route: OverlapRoute
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var theme: KabanTheme { .init(dark: scheme == .dark) }
    private var ids: [TaskID] { store.projection?.tasks[route.task]?.overlapsWith ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Пересекающиеся задачи", systemImage: "square.on.square").font(.system(size: 18, weight: .semibold)); Spacer(); KabanIconButton(symbol: "xmark", help: "Закрыть · Esc") { dismiss() } }
            Text("Предупреждение от службы: задачи затрагивают общие файлы. Пересечение само по себе не останавливает запуск.")
                .font(.system(size: 12)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if ids.isEmpty { Text("Текущих пересечений нет").font(.system(size: 12)).foregroundStyle(theme.secondary) }
                    ForEach(ids, id: \.self) { id in
                        if let card = store.projection?.tasks[id] {
                            Button { dismiss(); Task { await store.openRelatedTask(id) } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(card.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                    Text("\(id.rawValue) · \(store.projection?.projects[card.projectId]?.name ?? card.projectId.rawValue)\(store.visibleIDs.contains(card.projectId) ? "" : " · скрытый проект")")
                                        .font(.system(size: 10)).foregroundStyle(theme.secondary).lineLimit(2)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        } else { Text("\(id.rawValue) · сведения о задаче недоступны").font(.system(size: 12)).foregroundStyle(theme.secondary).textSelection(.enabled) }
                    }
                }
            }.frame(maxHeight: 340)
        }.padding(20).frame(width: 520).background(theme.window).foregroundStyle(theme.text)
    }
}
