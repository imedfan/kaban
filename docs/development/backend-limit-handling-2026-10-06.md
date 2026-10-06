# BE-15: лимиты Cursor и пробный запуск после тихого выхода

Дата: 6 октября 2026. Ветка `codex/be-15-limit-handling`, база — `codex/be-14-model-catalog`
(`fa275e6`, [PR #80](https://github.com/imedfan/kaban/pull/80), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Реализация — `4de3cea`.
[PR #81](https://github.com/imedfan/kaban/pull/81) открыт поверх #80 и ещё не принят в main.

## Реализовано

`CursorLimitClassifier` различает пустой текст (nil), `spendLimitHit` / `usage limit` / `usage_limit` (`.usageExhausted` с пулом run), `resource_exhausted` и «not available in the slow pool» (`.modelUnavailable`), `rate limit` / `rate_limit` / «too many requests» (`.rateLimit`), `authentication failed` / `invalid api key` / `unauthorized` (`.runnerAuth`). Любой другой непустой текст — `.unknown`, без приведения к известному классу. Строка с `@`, token, secret, key или `sk-` в диагностике заменяется на «Неклассифицированная ошибка.» Дата сброса читается из ISO-8601 `Z` в тексте.

Cooldown — 15, затем 30, затем 60 минут. Шаг растёт, только пока предыдущий флаг ещё не истёк; после снятия следующий удар снова шаг 1. Неизвестный reset usage — 6 часов, либо `billingCycleEnd`, либо разобранная дата. `QuotaState.freePercent` возвращает nil, если процента пула нет: это не 100% свободно и не 0% занято. Проактивный блок по-прежнему пропускается, когда процента нет.

`raiseRateLimit`, `raiseUsageExhausted`, `raiseRunnerUnavailable` и `requestModelProbe` пишутся в той же транзакции `apply` и не попадают во внешний outbox. `observeAgentFailure` классифицирует текст одного running run. Известный класс освобождает только этот run. Соседний run остаётся `.running`. Unknown пишет одну строку feed `limit_unclassified` и receipt по commandId; повтор не дублирует строку, попытки не меняет и флаг не ставит. Пул берётся из разрешённой модели стадии (override важнее pipeline). `resumeAfterRateLimit` снимает только `rateLimited` и поддержан в `DaemonService`.

Тихий exit 0 — `silent_exit`, `retry_wait(.silentExit)`, попытка не списывается. `requestModelProbe` записывает `model_probe` (`model_probe_v12`): одна строка на модель, `next_at` не раньше чем через 10 минут. Повтор внутри окна не сдвигает срок и не запускает процесс. Задача в `retry_wait(.silentExit)` не выбирается обычным стартом, поэтому тихий выход не становится циклом нового run. `cursor-agent -p` не вызывается.

Process-pass читает не больше 4000 байт stdout и stderr. Известная лимитная фраза классифицируется до `no_final_call`. Обычный текст вроде `activity` остаётся `no_final_call`. Сырой текст с секретом в pass line и в payload не копируется.

## Границы

Платный `-p` и живые лимитные fixtures CLI не запускались. Установленный CLI не залогинен. Проба записывает срок и не исполняет короткий промпт. Exactly-once внешнего процесса нет. `--approve-mcps` не передаётся. Чтение `state.vscdb` не делается.

## Проверки

- `CursorLimitTests`: классы, redact, шаги cooldown, nil-процент не равен 100, дата `2026-10-06T12:00:00Z`.
- `LimitHandlingTests`: rate limit освобождает только упавший run, сосед остаётся `.running`, попытки и `runsSinceHuman` не растут, reopen сохраняет cooldown, `resumeAfterRateLimit` снимает его, следующий удар после снятия снова шаг 1. Второй удар при живом флаге даёт шаг 2 и 30 минут. Om usage не блокирует старт cm; cm usage с датой не ставит флаг Мака. Unknown usage блокирует cm. Секрет не попадает в `task_detail`. Повтор unknown не добавляет вторую строку. Тихий выход пишет одну пробу на модель; второй тихий выход той же модели внутри 10 минут не двигает `next_at` и не оставляет `requestModelProbe` в outbox. Старт из `retry_wait(.silentExit)` отклоняется.
- `ProcessControlTests`: скрипт с «Too many requests» даёт `rate_limit`, `retry_wait(.rateLimit)` и нулевые счётчики. Два запуска `KabanDaemon --process-pass` печатают одну и ту же пару строк и не порождают второй процесс. Cooldown после этих запусков совпадает.
- Существующие `testPoolAndModelFlagsSkipCandidatesReleaseRetryWIPAndPreserveRuns` и `testQuotaReserveCustomPoolAndUnknownOrStaleValues` остаются зелёными: om-флаг не останавливает выбор cm, nil-процент cm не блокирует старт.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 434 tests, 0 failures (Transport 23, Protocol 64, Kit 170, DaemonCore 111, Board 66).
