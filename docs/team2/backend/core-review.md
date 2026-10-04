# T9 — Protocol / BoardCore: catch-up, pending, drop boundaries

Дата 2026-10-04. Ветка `team2/backend-t9-core-review`; baseline `origin/main` `1d647ea`. Read-only review Sources/KabanProtocol и KabanBoardCore; источники architecture v0.11.22 §5/§11, spec v0.8.24 UC-11/UC-12, frontend-plan v0.5.36 §2. Только новый отчёт; production и существующие тесты не менялись. Уверенность высокая для приведённых actual outputs, средняя для integration impact.

## Подтверждённая reducer inconsistency

| Приоритет | Код | Требование и actual | Предложение / issue |
|---|---|---|---|
| major | Sources/KabanBoardCore/BoardProjection.swift:336–340 | Arch §5: openIncidentCount — «сумма ProjectSummary.openIncidentCount». `.projectUpdated` заменяет authoritative project count, но global count остаётся старым. Snapshot global0/project0 → projectUpdated count2: global0, badge2 | Согласовать global aggregate при authoritative project updates и протестировать journal ordering. [#44](https://github.com/imedfan/kaban/issues/44) |


Reducer inconsistency и отдельный robustness question воспроизведены через публичный API, transient `/private/tmp/kaban-team2-context/T9-probe.swift`, linked с уже построенными библиотеками; exit0. Вывод:

```text
applied
projectUpdated global=0, project=2
applied
old subscription stateSeq=11, title=old
```

Минимальные входы первого случая:

```swift
let project = ProjectSummary(id: "p", name: "P", path: "/synthetic", mascotSeed: "p")
var board = BoardProjection(snapshot: Snapshot(seq: 10, projects: [project], pipelines: [], tasks: []))
var changed = project
changed.openIncidentCount = 2
board.apply(EventEnvelope(seq: 11, at: Date(timeIntervalSince1970: 0), projectId: "p",
                          event: .projectUpdated(changed)))
// board.openIncidentCount == 0, board.badgeCounts(for: "p").openIncidents == 2
```

P2 robustness question (не подтверждённый runtime bug): взять snapshot seq20 с task `t` в paused; вызвать `openSubscription(SubscriptionID(projectIds:["p"]), from:10)` и применить taskUpdated seq11 через эту подписку. Source `appliedSeqs` пуст после snapshot, поэтому старое событие повторно редуцируется и stateSeq (BoardProjection.swift:247) становится 11. Обычный `.all` stream со snapshot cursor20 это событие отсечёт: архитектура предписывает subscribe от seq снимка, поэтому older anchor может быть ошибкой caller. Public openSubscription(from:) (BoardProjection.swift:196) не документирует явный запрет старого anchor. Требуется precondition documentation/guard или snapshot floor; до решения issue не заводим. Existing BoardProjectionTests.testSecondSubscriptionDoesNotApplyTheSameSeqTwice покрывает subscriptions с одинаковым fromSeq10, не older-than-snapshot.

Порядок projectUpdated(count1) перед incidentOpened(newid) дополнительно даёт project2/global1; owned test показывает обратный порядок (incidentOpened, затем projectUpdated). Контракт daemon writer/event ordering надо уточнить прежде, чем утверждать production double count; standalone authoritative count inconsistency подтверждена независимо.

## Что проверено и что не объявлено багом

- Protocol DTO — value types Codable/Hashable/Sendable; нет общей изменяемой formatter: Coding.swift создаёт ISO8601DateFormatter локально на каждый encode/decode. Существующий Swift 6 build успешен. Это не runtime actor/TSAN доказательство; shared decoder экземпляр caller не должен использовать concurrently.
- Unknown JournalEvent/EphemeralEvent tags совместимы со старым клиентом; BoardProjection consumes seq для unknown, а ephemeral не двигает seq/cards. Existing RoundTripTests и BoardProjectionTests покрывают это. Unknown payload намеренно не сохраняется для transparent forwarding; такого требования нет.
- Snapshot→subscribe, duplicate/gap/resync handling: обычная одна `.all` subscription последовательно держит cursor; gap блокирует её до snapshot. `replace` сохраняет pending marks — это явно заявлено; нужны reply-seq reconciliation/timeout на XPC adapter level.
- PendingCommands снимает mark на matching taskUpdated.commandId или noteCommandError. Другой commandId/nil оставляет mark; card заменяется целиком. Frontend §2 именно это задаёт для task-changing commands. Non-task command acknowledgement via own event/reply seq остаётся adapter responsibility, API здесь его не реализует. Не заводим отдельный баг без writer/adapter contract.
- DropRules запрещает cross-project, same-column, gate-column и forward, кроме соседней стадии queue с acceptance criteria; running/gating backward требует confirmation. Existing BoardSetAndDropTests покрывают эти классы. Никакого XPC mutation core не выполняет.
- DropRules использует display.order, не граф onSuccess. Spec говорит «назад/первая стадия», но не определяет связь разрешённого visual reordering с graph order. Вопрос: какой порядок является authority для ручного старта, если display и graph различаются? Не объявляется подтверждённым багом.
- DropRules не проверяет terminal lifecycle и может показать backward move для done/cancelled; TaskMachine отклонит human command для final state. Требуется UI eligibility gate или запрет в core? В spec UC-11 нет явной lifecycle matrix для drag; отмечено как integration вопрос.
- Snapshot init использует Dictionary(uniqueKeysWithValues); duplicate project/task/pipeline IDs могут trap. Protocol принимает массив без uniqueness validation. Источник — trusted daemon snapshot; контракт уникальности не описан как защита от malformed input. Определить fail-closed decode/resync policy, прежде чем считать это production issue.
- Known TaskDetail missing artifacts/gitGrants/gitDenials уже описан [#14](https://github.com/imedfan/kaban/issues/14); не дублируется. Анализ полной документации/validation text — A1/AN4, в T9 не повторяется.

## Проверка / доставка

Статические источники и owned tests прочитаны; два внешних deterministic probes (одна inconsistency и один contract question) выполнены Swift 6.4/macOS arm64. Новый полный suite для документа не запускался: source baseline тот же, B4 full run уже exit0 (211 XCTest, один conditional known-issue skip). Linux новой ветки не запускался. Новых тестов T9 не добавляли: проверенные регрессии должен закрепить владелец при исправлении; findings не исправлялись. В diff только `docs/team2/backend/core-review.md`; local commit, без push/PR/merge. Issues/публикацию координирует root.
