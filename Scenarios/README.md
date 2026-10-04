# Сценарии приёмки M1

Автор: Kaban Analyst Bot. Источник: спека v0.8.3 (`docs/kaban-mvp-features-usecases.md`) и архитектура v0.11.1. Критерии приёмки по всем UC и вехам лежат в `/workspace/kaban/acceptance-criteria-v0.md` (в репозитории `docs/acceptance-criteria-v0.md`).

JSON не править руками: источник это `gen_m1.py`, файлы пересобираются командой `python3 gen_m1.py`. Типы на проводе те же, что в `KabanProtocol`: состояние задачи `{status, reason}`, команда `{protocolVersion, commandId, command: {имя: {поля}}}`, событие `{type, data}`, флаг `{level, flag, ...}`.

## Формат
```json
{ "id": "M1-RETRY-01", "uc": ["1.4", "UC-10"], "title": "...",
  "given": { "clock": "...", "pipeline": "base", "tasks": [ { "id", "projectId", "stage", "state", "attempt?", "autoRuns?", "bounces?", "runId?", "modelOverride?" } ],
             "flags?": [], "modelFlags?": [], "stageModels?": {}, "maxConcurrentRuns?": 4, "acceptedFiles?": {} },
  "steps": [ { "command" | "driver" | "tick" | "advance" | "pipelineApplied": ..., "then": { ... } } ] }
```
Шаг выполняется в порядке `advance` → `command` / `pipelineApplied` / `driver` → `tick`, затем проверяется `then`.

- `advance`: сдвиг фейковых часов (`30s`, `2m`, `15m`).
- `tick: "scheduler"`: один проход планировщика.
- `driver`: фейковый драйвер завершает текущий run задачи. `end` — значение `RunEndReason` (`completed`, `crash`, `stall_timeout`, `gate_failed`, `rate_limit`, `runner_auth`, `daemon_restart`, `silent_exit`, `model_substituted`, `returned`, `asked_human`). Дополнительно: `gates: green|red`, `to` для `returned`, `actual` для подмены, `dirty` для грязного клона, `branchFiles` (diff ветки для `suspicious_files`), `gitDenied: N` (N отказов без завершения run).
- `pipelineApplied`: в `main` закоммичена версия пайплайна с указанными изменениями стадий.

`then` проверяется **частично**: сверяются только перечисленные поля.
- `tasks.<id>`: `stage`, `state`, `suspiciousFiles` (полный `SuspiciousFile`: `path`, `rule`, `pattern?`, `sizeBytes`, `blob`), `attempt` (номер текущей попытки на этот заход в стадию), `autoRuns` (счётчик для `max_runs_per_task`), `bounces`, `retryAt` (относительно часов шага).
- `events`: журнальные события, которые должны появиться в этом шаге, в этом порядке. Лишние события допустимы. `data` сверяется по подмножеству полей, `commandId` (если указан) сверяется с конвертом `EventEnvelope`.
- `taskUpdated` генерируется автоматически после каждого шага, где у задачи изменилось хоть одно поле карточки. В `data` лежит **полная** `TaskCard`, как на проводе (арх. §5), её можно проигрывать в `KabanBoardCore` как есть. Поля, которые сценарий не задаёт (`title`, `branch`, `maxAttempts`, `updatedAt` и т. п.), заполнены значениями по умолчанию. Тест демона сверяет только поля из `check` (`id` и изменённые в шаге). Порядок `taskUpdated` относительно предметных событий того же шага не проверяется: демон шлёт их в одной транзакции. В шагах с `commandError` событий нет.
- `ephemeral`: эфемерные события.
- `flags`: полный список активных флагов планировщика после шага; `[]` значит, что флагов нет.
- `runsStarted` / `runsKilled`: сколько run стартовало или было убито в шаге.
- `runningByProject`, `clone` (`kept` / `reset`), `refs`, `probes`, `runEnd`.
- `commandError`: ожидаемая ошибка команды; `acceptedFiles`: принятые файлы задачи.
- Ключи `bounces` (`bounceByReason`): `<from>_<to>` по id стадий (`test_dev`, `ai_review_dev`) и `merge_conflict`; общий итог отдельным полем, не ключом.
- Предметные события (`suspiciousFilesFound`/`Accepted`, `humanRequested`, `pipelineDraftValidated`, `modelFlagsChanged`) дополнены до полного типа протокола; сверяются только поля из `check`. `contentHash: "sha256:any"` и `message: "…"` это заглушки, их не сверяют.
- `note`: пояснение для человека, не проверяется.

## Базовый пайплайн `base`
Стадии: `backlog` (manual) → `dev` (agent, WIP 3) → `test` (agent, WIP 2) → `ai_review` (agent, read-only, WIP 2) → `human_review` (human, WIP 5) → `merge` → `done`. Модель по умолчанию у всех agent-стадий `composer-2` (Cm), если `stageModels` не переопределяет. Лимиты по умолчанию из раздела 4 спеки: 3 попытки и паузы `[30s, 2m]`, `max_runs_per_task` 12, `max_waiting_human` 3, возвраты 3 / 2 / 2 / 5, cooldown rate-limit 15 → 30 → 60 мин, пресет git «Стандартный», 5 отказов git за run, `suspicious_files` по умолчанию из архитектуры (`.env*`, ключи, больше 5 МБ, `allow: [.env.example]`).

## Что покрыто
33 сценария. Они покрывают переходы и WIP, ретраи и паузы, счётчик попыток на заход в стадию, запуски, которые не списывают попытку, `max_runs_per_task`, возвраты, `max_waiting_human`, флаги модели и пулов, `pipeline_invalid` и валидацию, паузы и отмену, справедливую раздачу слотов, подмену модели, отказы git и `suspicious_files`. Слияние, MCP, квота перед стартом и Seatbelt идут в M2–M4, см. критерии приёмки.

## Проверка декодирования
`ScenarioDecodeCheck` читает только `.json` прямо в указанной папке, поэтому путь должен вести в `M1`: `KABAN_SCENARIOS=Scenarios/M1 swift test`. Без переменной тест пропускается. Если переменная задана, а папки нет или в ней нет ни одного `.json`, тест падает. Реплей KabanKit ведёт себя так же. В CI задаётся `KABAN_SCENARIOS=Scenarios/M1`.
