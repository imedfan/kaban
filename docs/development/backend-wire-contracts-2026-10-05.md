# BE-01: расширенные wire-контракты

База — `origin/main` `8d992e6`, PR #70 принят. Ветка —
`codex/backend-wire-contracts`. Поручение — первая задача очереди
[Backend MVP BE-01–20](backend-mvp-tasks.md); вся очередь остаётся в работе.

## Результат и границы

| Поверхность | Реализация | Следующая зависимость |
|---|---|---|
| Capabilities | Полный каталог всех 50 CommandName и 7 transport operations; exhaustive switches | Обновлять support при реализации BE-02–20 |
| Replacement/session | Snapshot и current live values под publisher lock; два раздельных cursors; наблюдаемые connection states | App integration |
| Ephemeral | Volatile ring/current, 512 записей/4 МиБ каждый, barriers, partial pages, restart/retention, backpressure | Producers Cursor/model/MCP/quota |
| Draft transfer | Exact UTF-8 YAML + SHA-256 + обязательная nullable base version + project | Production apply/commit/recovery BE-03 |
| Validation | Production parser/validator/resolver для зарегистрированного проекта, active-stage protection; binding checks в DB transaction | Production project lifecycle BE-02; полный pipeline storage BE-03 |
| Logs | Read/tail DTO и клиент с record offsets, bounded batches, EOF/error | Storage/redaction/retention BE-16; server readLog=false |
| Cursor environment | Path/discovery DTO, get/configure команды, reply и correlated event | Driver/environment/LaunchAgent BE-07/20; server unsupported |
| WIP restore | Task/run/ref команда и correlated event; без произвольного path | Ownership/effect/recovery BE-18/19; server unsupported |

Типы будущих ответов/events не являются готовностью соответствующего backend.
`configureCursor`, `getCursorEnvironment`, `restoreWIP`, `readLog` и применение
pipeline явно отказывают. Global pause/settings работают durable; task/project
команды отмечены managedFakeOnly. Полная таблица запрашивается через capabilities.
Missing runner/log/квота не превращаются в успешные пустые данные.

`updatePipeline` сохраняет старый shape и совместимо добавляет optional draft.
Hash-only запрос без серверного draft получает pipeline_draft_required. Exact
project/base/content/hash сверяются до попытки применения; stale/hash refusals
сохраняются как обычные wire receipts. Даже согласованный draft сейчас получает
unsupported_command: запись `.kaban/` и её git commit не симулируются.
`validatePipelineDraft` — fresh query без receipt; legacy validatePipeline
возвращает прежние pipelineVersion/validationIssues. Ни общий validator, ни fake
исключение merge_count не ослаблены. SHA-256 реализован portable по
[FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final), сверяется со стандартными
векторами и CryptoKit на macOS; он используется для identity содержимого.

## Контракт для потребителя

См. архитектуру §5 и [frontend fixtures](../frontend/protocol-fixtures.md).
`sessionUpdates()` — новый opt-in stream. Сначала connecting/synchronizing,
replacement; после journal/live catch-up — connected. Потеря соединения сохраняет
оба cursor и сообщает reconnecting; journal gap или новая live incarnation дают
replacement. `.ok` и connected не снимают pending command. Frontend интеграция
этого API пока не выполнена, существующий watch по-прежнему snapshot/event-only.

Live envelope не имеет durable seq. Его afterSeq — нижняя journal граница;
новое durable schedulerFlags событие не может быть перезаписано старым live flag.
Current values могут пережить обрезку replay ring. Переполнение count/bytes у
publisher отклоняет публикацию без продвижения cursor; обрезанный replay требует
reset/replacement. Переполнение клиентского stream завершает его явной ошибкой.

Log offsets — номера нормализованных AgentEvent records. Client проверяет runId,
from/next/end/available offsets и размер страницы. Недоступный лог и потерянный
prefix дают ошибки; tail возобновляется с последнего потреблённого nextOffset.
Сырой JSONL и его byte offsets не выдаются за эти offsets. Реальный storage отсутствует.

## Приёмка BE-01

| Критерий | Авторитетное доказательство |
|---|---|
| Legacy snapshots/commands/details; unknown fields допустимы, malformed known отклонены | Старые golden/legacy suites без изменения обязательных полей; WireContractTests проверяет новый draft/base, malformed draft и live envelope |
| Replacement согласован по seq; эфир не аллоцирует durable seq | SessionContractTests проверяет snapshot/current, journal count, barrier delivery, retention/incarnation и stale live flags; настоящий XPC и stdio smoke |
| Чужой project/version/different hash не применяется | checkBinding внутри execute transaction; SessionContractTests проверяет stale/hash refusal, неизменный snapshot и receipt replay; WireContractTests — exact content/nullable base |
| Fixtures каждой новой операции | daemon-contracts.json: request/response/applicable journal или live/refusal; connection-states.json. Read operations не порождают events, log records — внутри batch |

## Проверки

- macOS Swift build и полный `KABAN_SCENARIOS=Scenarios/M1 swift test`: 344 tests,
  failures=0. Это включает private-endpoint XPC exchange новых operations.
- Linux Swift 6.1.3/aarch64: build, полный сценарный прогон 342 tests, failures=0,
  расширенный process smoke. XPC tests доступны только на macOS.
- Unsigned Kaban.app build прошёл. App/views/runtime не менялись; настоящее окно,
  светлая/тёмная тема и accessibility в этом backend-инкременте не проверялись.
- Process smoke macOS, context checker и final diff прошли.

Среда: nested sandbox SwiftPM/Xcode не разрешал запись кешей; проверка выполнена
вне sandbox. Один incremental Xcode/SwiftPM link использовал старый объект с
предыдущей сигнатурой initializer; свежий scratch build прошёл без изменения
production-кода или ослабления assertions. Linux использовал одноразовый контейнер
с read-only mount и собственной копией исходников.

Подписанный Mach service/Team-ID refusal, launchd registration, real CLI/git/MCP,
logs/redaction и восстановление WIP остаются своими задачами. BE-01 не объявляет
готовность M1/MVP. Следующий обязательный инкремент очереди — BE-02.
