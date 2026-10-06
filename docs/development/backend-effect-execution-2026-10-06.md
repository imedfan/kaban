# BE-05: claim, lease и receipt внешних эффектов

Дата: 6 октября 2026. Ветка `codex/be-05-effect-execution`, база после fetch —
`origin/main` `77a0dc1` (срез статуса #75; BE-04 принят в #74).
Очередь — [backend MVP](backend-mvp-tasks.md). PR открыт в main и ещё не принят.

## Реализовано

Поверх существующих effect id и outbox добавлены claim, fencing lease, external fact
и receipt. Additive migration v7 дописывает колонки и не меняет INSERT постановки эффекта,
поэтому исходный payload остаётся байт в байт. Два соединения выбирают одну строку,
но UPDATE с `changes = 1` отдаёт lease только одному. Истёкший claimed lease без факта
можно взять снова; это не обещание, что процесс выполнился не больше одного раза.
Факт `started` фиксирует наблюдение: эффект не перезапускается и receipt ещё нет.
`finished` с outcome сходится в один receipt. Тот же факт идемпотентен. Другой payload
или другой action id даёт `effectResultConflict`. Старый lease получает `effectLeaseStale`.
Уже superseded эффект не применяется и не возвращает отменённую задачу в работу.

Факт записывается отдельной транзакцией до receipt. Сбой journal при commit откатывает
переход, статус и receipt; факт и payload остаются. Проверка актуальности task/stage/run
стоит до команды автомата. Process/git side effect в opt-in проходе пишется в файл
после commit claim и до транзакции receipt. `deliverFake` отклоняет production до
сравнения сохранённых байтов и не является путём настоящего результата.

Каждый старт демона вызывает `recoverEffectExecution` с возвратом незавершённых leases:
предыдущий процесс мёртв, потому что WriterLease эксклюзивна. `--effect-pass` не включён
по умолчанию. Он protocol-подтверждает только `killRun`, `saveWipAndRollback`,
`commitStage`, `scheduleRetry`, `expireGitGrants`, `cleanupClone` и `notifyHuman`.
Agent, gate и merge остаются pending. Повторный запуск печатает уже сохранённый receipt
и не дописывает side-effect файл.

## Границы

Cursor CLI, каталог моделей, квота, создание и удаление клона, process group, kill
по pid и exactly-once внешнего процесса не входят в этот инкремент. Protocol receipt
не выполняет git, не удаляет каталог и не шлёт уведомление. Следующая задача — BE-06.

## Проверки

- `EffectExecutionTests` на свежей БД: два worker, crash до факта и после finished fact,
  stale lease, superseded cancel, идемпотентный receipt, конфликт payload, откат trigger
  `BEFORE INSERT ON event`, отказ `deliverFake` на production.
- Два запуска `KabanDaemon --effect-pass --stdio --database` на одной временной БД:
  один claim `killRun`, side effect после commit, тот же receipt после reopen.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 399 tests, 0 failures,
  включая legacy fixtures и `EffectExecutionTests`. `tools/check-project-context.py` прошёл.
