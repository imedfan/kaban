# BE-07: драйвер Cursor CLI

Дата: 6 октября 2026. Ветка `codex/be-07-cursor-driver`, база — `codex/be-08-process-control`
(`df7185e`, [PR #78](https://github.com/imedfan/kaban/pull/78), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Реализация — `3874b9e`.
[PR #79](https://github.com/imedfan/kaban/pull/79) влит в `codex/be-08-process-control` и ещё не принят в main.

## Реализовано

`CursorStreamParser` читает NDJSON по строкам. Неизвестный `type`, битый JSON и строка длиннее 1 МиБ дают диагностику и не обрывают следующие события. Неполная строка ждёт перевод строки. `session_id` берётся только из непустого поля `system/init`. Событие `result` не создаёт идентификатор. Отсутствующие token-поля остаются `nil` и не подменяются нулём.

`CursorLaunch` отклоняет пустую модель, `auto` и placeholder. Аргументы: `-p --output-format stream-json --model <id>`, `--force` только если стадия не read-only. `--approve-mcps` не передаётся. `--resume` добавляется только вместе с уже проверенным непустым session id и не отменяет `--model`. Без такого id сессия новая, а переданный текст задачи остаётся в prompt. Ключи окружения не попадают в argv, prompt и редактируемый вид окружения.

Prompt собирается из текста skill, задачи, handoff, замечаний, grants и правила финального MCP-вызова. Пустой skill остаётся фразой «Skill file was not loaded.» и не заменяется выдуманной ролью.

`CursorRunner.assess` смотрит на файл и, если он исполняемый, запускает `--version`, `status` и `--list-models`. Отсутствующий файл — `agent_missing`, файл без права на запуск — `agent_not_runnable`. Текст status про «not logged in» и родственные формулировки — `agent_not_logged_in`; «authentication failed» и родственные — `runner_auth`. Иной ненулевой status, включая «connection refused», флаг не ставит. В базу пишутся версия, причина и короткая заметка каталога. Текст status и секреты окружения не пишутся.

`recheck(.runner)` делает эту проверку сразу. Повтор того же commandId процесс не запускает. `nextCheckAt` — через 300 с. `runSchedulerPass` вызывает проверку только если путь задан и срок наступил. `--cursor-agent` записывает абсолютный путь; без флага демон Cursor не вызывает. `configureCursor` и `getCursorEnvironment` остаются unsupported.

## Границы

Платный `-p` и живой stream установленного CLI не снимались. Разбор проверен на NDJSON задокументированной формы, не на оплаченном запуске.
Сравнение display name с каталогом и `model_substituted` остаются BE-14. Тихий exit и probe остаются BE-15.
Login под launchd, MCP discovery и timeout модельного запуска не проверялись. `--approve-mcps` не включён: preflight MCP — BE-10.
Чтение skill-файла из выбранной версии pipeline не встроено в scheduler. Process-pass по-прежнему запускает переданный `--runner`, не Cursor.
На этой машине CLI не залогинен, поэтому каталог моделей и числовые лимиты квоты не наблюдались.

## Проверки

- `CursorDriverTests`: неизвестное событие, обрыв строки, битый JSON, строка длиннее 1 МиБ; пустой и чужой `session_id` не становятся resume id; usage без поля не равен нулю; `auto` и placeholder отклоняются; resume без id сохраняет текст и не ставит `--resume`; ключ не попадает в argv, prompt и redacted env; отсутствующий и неисполняемый файл, «not logged in» и «authentication failed» дают соответствующие причины.
- `CursorRunnerStoreTests`: `agent_missing` и `agent_not_runnable` без запуска неисполняемого файла; «not logged in» ставит флаг и `nextCheckAt` +300 с; повтор commandId и ранний scheduler pass процесс не повторяют; кнопка `recheck(.runner)` повторяет проверку до срока; pass в срок снимает флаг, когда status больше не сообщает logout; маркер из status не попадает в payload; reopen сохраняет версию.
- Два запуска `KabanDaemon --stdio --cursor-agent` на одной временной БД с локальным скриптом печатают один и тот же снимок `runner_unavailable` / `agent_not_logged_in`, версию `2026.09.23-test` и три вызова (`--version`, `status`, `--list-models`). Скрипт не запускает `-p`.
- Реальный запуск `/Users/artem/.local/bin/cursor-agent` без `-p`: `--version` exit 0, `2026.09.23-86fc751`; `--list-models` exit 1, `Authentication required`; `status` exit 0, `Not logged in`. Это не вывод `--help`.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 421 tests, 0 failures (Transport 23, Protocol 64, Kit 166, DaemonCore 102, Board 66).
- Linux Swift 6.1: `CursorDriverTests` 4 и `CursorRunnerStoreTests` 2 проходят.
