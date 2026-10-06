# BE-09: MCP-сервер доски

Дата: 6 октября 2026. Ветка `codex/be-09-mcp-server`, база — `codex/be-15-limit-handling`
(`2288ee5`, [PR #81](https://github.com/imedfan/kaban/pull/81), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Реализация — `7d062b1`.
[PR #82](https://github.com/imedfan/kaban/pull/82) открыт поверх #81 и ещё не принят в main.

## Реализовано

Loopback HTTP на `127.0.0.1` с портом, который выбирает ОС. Отдельной HTTP-библиотеки нет: сокет POSIX в `MCPBoardServer`. Принимается только `POST /mcp`. `Authorization: Bearer` обязателен. Ответ — JSON-RPC: `initialize`, `tools/list` и `tools/call`.

Инструменты: `get_task_context`, `report_progress`, `complete_stage`, `return_to_stage`, `request_human`. Мутации идут через `TaskMachine` и `KabanStore.apply` в одной записи SQLite. Нелегальный переход возвращает текст автомата и не меняет задачу.

Сырой токен — 32 байта из `/dev/urandom`, один раз в окружение процесса как `KABAN_RUN_TOKEN`. В `mcp_run_token` (`mcp_run_token_v13`) хранится SHA-256. Строка помнит project, task, stage и run. Новый токен того же run отзывает прежние. Смена `currentRunId` отзывает токены закончившегося run. Повтор `complete_stage` того же токена не создаёт второй переход: command id стабилен, а `complete_command_id` делает повтор успешным. Другой `taskId` в arguments отклоняется. Чужой, отозванный и токен прошлого run получают 401 и не пишут payload.

`complete_stage` переводит `running` в `gating` и кладёт `.runGates`. Стадия остаётся текущей, Done не выставляется. `request_human` переводит в `waiting_human: question`, очищает `currentRunId` и освобождает слот `maxConcurrentRuns`. `report_progress` дописывает feed `progress` и `updatedAt`, статус не меняет; если есть строка `agent_process`, обновляется `lastActivityAt`. Summary и дополнительные artifacts пишутся в `task_detail`. Issues успешного `return_to_stage` пишутся как kind `issue`. Вопросы пишутся существующим путём human request.

Текст поля не длиннее 4096 байт. Issues и artifacts — не больше 20. Тело HTTP — не больше 65536 байт. Недоставленные git-grant этой задачи возвращаются в `notices` этого ответа и помечаются `mcpResponse`. Чужая задача их не видит. Повтор не присылает то же уведомление.

`--mcp-pass` выполняется до recovery, пока run ещё `.running`. Первый проход делает один `complete_stage` и печатает `mcp complete <run> gating`. Следующий проход печатает сохранённую строку. Cursor при этом не запускается.

## Границы

Сервер не висит на обычном запуске демона: его поднимают тест и `--mcp-pass`. `mcp.json`, белый список и подмена конфига клона остаются BE-10. `listProjectMcpServers` и `setProjectMcpAllowlist` остаются `.unsupported`. `/git/check`, Seatbelt и исполнение allow-once остаются следующими задачами. Уведомление о grant только помечает delivery; создание grant и списание — не этот инкремент. Токен не пишется в клон, process record, pass line и DTO. Exactly-once внешнего процесса нет.

## Проверки

- `MCPServerTests`: чужой bearer — 401; подмена `taskId` не меняет ни одну задачу; токен после `runFailed` и нового run — 401; после `request_human` тот же токен не пишет progress. Повтор `complete_stage` с другим summary оставляет один переход в `gating`, summary и artifact первого вызова, эффект `.runGates`, стадию agent и не Done. `return_to_stage` на стадию вне `returnsTo` отклоняется. `request_human` освобождает слот соседа при `maxConcurrentRuns` 1. Notice `git rebase` видит только адресат; второй ответ пустой; сосед получает только свой grant. Сырой токен отсутствует в sqlite, wal и shm и не печатается процессом. `tools/list` называет пять инструментов. Хост — `127.0.0.1`.
- Два запуска `KabanDaemon --mcp-pass --stdio` печатают одну и ту же строку `mcp complete run-a gating` и оставляют один переход в `gating`.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 440 tests, 0 failures (Transport 23, Protocol 64, Kit 170, DaemonCore 117, Board 66).
