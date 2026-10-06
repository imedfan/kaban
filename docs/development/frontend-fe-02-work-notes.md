# FE-02: промежуточное состояние работы

6 октября 2026. Ветка `codex/fe-02-session-recovery`, отдельный managed worktree.
Основа подготовки — FE-01 `b0f4387`; fetched `origin/main` пока `5b4fdc5`.
PR FE-02 в main не открыт: сначала должна быть принята зависимость
[FE-01 / #92](https://github.com/imedfan/kaban/pull/92). Перед PR база обновляется,
чтобы diff содержал только FE-02. Это checkpoint, не отчёт завершённой приёмки.

## Реализовано в Core

- Точный CommandEnvelope и receipts сохраняются как прежде; pending теперь
  различает отправку, неизвестную доставку, ожидание event/effect и отказ.
- Typed scopes: task/project/global/pipeline/grant/denial/model. Read-only
  запросы не записываются в mutation journal.
- Совпадающий commandId без нужного типа события и ресурса не подтверждает
  результат. Создание проверяет projectId, редактирование — taskId.
- После retention обычный mutation receipt разрешается только после применения
  authoritative snapshot, покрывающего его seq. Карточки локально не переводятся.
- Restore receipt и taskUpdated не означают успешного восстановления git;
  нужен wipRestored с точными taskId/runId/ref. Поздняя ошибка транспорта не
  отменяет уже наблюдавшееся подтверждение.
- Журнал FE-01 декодируется без новых полей. Его прежний eventSeq сохраняет
  metadata, но не подменяет отсутствующий подтверждающий тип события;
  для unresolved legacy records требуется replay/reconciliation.

`KABAN_SCENARIOS=Scenarios/M1 swift test --filter KabanBoardCoreTests`:
**75 tests, 0 failures**. Четыре новых теста проверяют unrelated correlation,
receipt/snapshot barrier, отсутствие ложного restore completion и legacy journal.
Существующий creation test дополнен отрицательным событием из другого проекта;
happy path fixture исправлена на реально запрошенный проект `shop`.

## Обязательная оставшаяся работа

Интегрировать Core в BoardStore: replay исходных pending envelopes, завершение
создания после replacement, scoped блокировки, состояния ожидания в UI,
сохранение drafts и selection, остановка/возобновление одного update stream,
наблюдаемое восстановление после gap/overflow. Проверить stale detail responses,
barriers ephemeral и очищение прежних volatile значений. Провести fault-injected
live QA и визуальную проверку настоящего окна, затем открыть отдельный PR.
Критерии [FE-02](frontend-mvp-tasks.md#fe-02-реализовать-состояние-соединения-catch-up-и-восстановление-проекции)
не отмечены выполненными.

Для restore нужно доказательство терминального исхода после retention.
`StoreWIPRestore.executeWIPRestore` сохраняет `.ok` с текущим seq до исполнения
git; `StoreEffects.commit` не обновляет этот wire reply. Успех даёт correlated
wipRestored; отказ — correlated taskUpdated и durable FeedItem вида
`wip_restore_failed`. FeedItem не имеет typed commandId/outcome, а повтор restore
того же run может быть самостоятельным намерением. Разбор внутренних effect ID
или текстов ленты не должен становиться публичным контрактом клиента. При
интеграции требуется структурированное доказательство исхода из daemon;
без него UI обязан сохранить неизвестность и не предлагать слепой повтор новым ID.
