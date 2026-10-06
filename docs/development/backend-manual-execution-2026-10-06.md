# BE-19: реальные ручные действия

Дата: 6 октября 2026. Ветка `codex/be-19-manual-execution`. База — BE-18 `c73e341`
([PR #89](https://github.com/imedfan/kaban/pull/89)), включая актуальный main `ea02f0c`.

Wire pause/resume/move/cancel/retry/answer/approve/reject используют существующий
автомат, серверную проверку targets/question IDs и durable correlated события.
Штатный DaemonScheduler теперь сериализует runtime pass с wire-командами: process stop
и WIP, restore, hooks/gates/result check, merge и cleanup проходят до нового admission.
Stop ждёт прекращения исполнения принадлежащего PID/birth перед rollback/cleanup.
Пауза проекта/Мака — только флаг планировщика. Override разрешён для agent stage,
сбрасывает runsSinceHuman через автомат и оставляет RunSpec текущего run неизменным.
Incident/suspicious-files/grants используют ранее реализованный lifecycle reducer/store.

Restore проверяет task/run/ref из durable history и recorded clone, фиксирует SHA в
outbox. До физического git нет correlated task event. Pending restore блокирует admission.
Восстанавливается дерево/index клона без перемещения HEAD/main. Текущий dirty clone
сначала сохраняется в отдельный WIP ref. Git marker по commandId позволяет после сбоя
между git и receipt подтвердить прежний результат, не переписав более поздние правки.
Receipt, feed, reset human counter и wipRestored атомарны. Отказ даёт durable feed
wip_restore_failed и correlated taskUpdated, без изменения counters/run summary.
Move/cancel supersede ещё не исполненный restore и снимают исходный pending через
correlated событие. Повтор commandId возвращает прежний reply без нового действия.

Проверки включают реальные shell/sleep/git процессы, остановку группы, архив при cancel,
restore/main/history, изменённый ref, foreign run, admission, marker после потерянного
DB receipt и immutable RunSpec при override. Итоговый полный прогон и smoke записаны
после проверки этого HEAD; результаты ниже.

Границы: отсутствующий runner сохраняет agent start pending; `--runner` подключает
явно выбранный локальный runner к обычному loop. Production Cursor launch/MCP lifetime,
CLI auth в изолированном профиле и остановка до первого Cursor tool не доказаны этим
инкрементом. Платный Cursor не запускался. Системная упаковка — BE-20.

Final validation: `KABAN_SCENARIOS=Scenarios/M1 swift test` passed: 507 tests, zero failures (Transport 23, Protocol 64, Kit 180, DaemonCore 174, Board 66). `swift build`, daemon/CLI process smoke, context checker and `git diff --check` passed. A regression covers archival and cleanup after removing a relinked project: retained metadata and the current origin path are used. Capability tests now require supported restoreWIP while configureCursor/getCursorEnvironment remain explicitly unsupported.
