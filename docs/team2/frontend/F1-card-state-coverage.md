# F-T2-1 — покрытие карточки по таблице 3.4

Источник: свежий frontend-plan-v0.md v0.5.36, §3.4, переданный team2-контекст;
архитектура v0.11.22, спека v0.8.24. Код после PR #8 в origin/main.
Добавлен только `Tests/KabanBoardCoreTests/Team2CardStateTests.swift`, без ресурсов.

## Граница результата

В KabanBoardCore есть BoardProjection и PendingCommands, но нет модели визуального
состояния карточки, `LimitReasonText`, выбора цветов/значков/действий, сортировки
бейджей или форматирования таймера. Все строки таблицы ниже имеют **нет API для
визуала**. Успех projection-теста означает сохранение daemon/wire данных, а не
соответствие нарисованной карточки макету. Не добавляли renderer в занятую зону.

Обозначения новых тестов:

- N1 — `testUncoveredReasonsSurviveSnapshotAndFullCardReplacement`: 24 явных
  state/reason cases; snapshot, полная замена и размещение по новому stageId.
- N2 — `testLimitsAndBadgesRemainDaemonDataRatherThanBeingRecomputed`: counters,
  model/grants/overlaps сохраняются, затем сбрасываются полной карточкой демона.
- N3 — `testPatternAndSizeSuspiciousRowsSurviveResyncWithoutTruncation`: pattern/size,
  текстовый/бинарный payload, три файла целиком через resync, затем очистка update.
- N4 — `testReadonlyFailureRemainsInItsDaemonSelectedStage`: first/second violation
  inputs сохраняются в стадии, которую прислал демон. Retry policy не вычисляется.

## Все строки §3.4 → evidence

| Строка таблицы | Existing / new input test | Результат / что отсутствует |
|---|---|---|
| queued (обычная, wip_full, quota_cm/om, model_flag) | Existing CatchUpTests.testResyncRequiredReplacesStateFromSnapshot (wip); N1 (quota/model); N2 criteria | projection OK; нет «#2», «Ждёт процесс», returned/answered priority marker renderer |
| running | Existing CatchUpTests.testEphemeralEventsDoNotTouchCardsOrSeq, BoardProjectionTests.testCardEventsReplaceTheWholeCard | projection OK; нет duration/model chip/progress text renderer |
| gating | N1 | projection OK; нет gate progress, Merge text или strict commit label |
| retry_wait crash/stall_timeout/wall_timeout/no_final_call/gate_failed | N1 | projection OK; нет countdown, retry explanation, attempts text |
| retry_wait rate_limit | N1 | projection OK; нет status text; charging belongs daemon/protocol |
| retry_wait runner_auth | N1 | projection OK; нет banner/action renderer |
| retry_wait daemon_restart | N1 | projection OK; нет restart text |
| retry_wait silent_exit | N1 | projection OK; нет probe progress text |
| retry_wait readonly_violation | Existing BoardProjectionTests.testStageLoadAndReadonlyViolationStayOnTheBoard; N4 | projection OK; нет readonly reason/timer formatting |
| waiting_human question | Existing BoardProjectionTests.testHiddenProjectKeepsBadgeCounts | projection OK; нет Answer action renderer |
| waiting_human review | Existing BoardProjectionTests.testHiddenProjectKeepsBadgeCounts | projection OK; нет review diffstat/conflict chip |
| waiting_human retries_exhausted | N1 | projection OK; нет exhausted text/actions |
| waiting_human run_limit | N1, N2 | projection OK; нет title/qualifier LimitReasonText or max_runs limit input on TaskCard |
| waiting_human model_substituted | N1 | projection OK; нет requested/actual card renderer; actual not a TaskCard field |
| waiting_human bounce_limit/conflict_limit | N1, N2 | projection OK; нет LimitReasonText/stage-specific actions; no client transition policy inferred |
| waiting_human git_denials | N1 | projection OK; нет refusal counter text/action renderer |
| waiting_human suspicious_files | Existing BoardProjectionTests.testDomainEventsGoToTheFeedOnly; ScenarioReplayTests.testSUSP01FoundFilesStayOnTheCardUntilAccepted; N3 | projection OK; нет truncation/+N/token/icon renderer; payload is never truncated by projection |
| waiting_human invalid_result | N1, N4 | projection OK; no retry budget/second-violation policy implemented on client |
| waiting_human incident | N1; existing BoardProjectionTests.testProjectIncidentCountSurvivesSnapshotAndFollowsTheJournal | state/count OK; нет red frame or rollback text renderer |
| paused | Existing PendingCommandTests.testTaskUpdatedWithMatchingCommandIdClearsSent | projection OK; нет Resume button renderer |
| blocked main_dirty | N1 | projection OK; нет merge-head detection/UI conflict hint |
| done/cancelled | N1 | projection OK; нет completion time/strike-through renderer |

Дополнение §3.4 «бейджи»: N2 покрывает **данные** bounceByReason, overlapsWith,
unusedGitGrants и model, а не приоритет grant > bounce > overlap > model,
максимум два и `+N`. Для порядка/токенов/VoiceOver пока нет API.

«Отправлено»: existing PendingCommandTests.testTaskUpdatedWithMatchingCommandIdClearsSent
и testCommandErrorClearsSentWithoutChangingTheCard, BoardProjectionTests.testDomainEventsGoToTheFeedOnly
уже проверяют matching commandId/error и отказ снимать метку предметным событием.
Не дублируем эти тесты. Расчёт текста действий/видимость disabled controls отсутствует.

## Проверки и ограничения

- Первоначальный `swift test --filter Team2CardStateTests` под внешней Codex sandbox
  не построил manifest: запись `/Users/artem/.cache/clang/ModuleCache` запрещена.
  Это ошибка среды, не падение нового assertion. Код выхода исходного swift
  скрывается последующим tail в shell, поэтому оценивается сам журнал ошибки.
- Полная suite запущена через разрешённый automatic review `--disable-sandbox`,
  CLANG_MODULE_CACHE_PATH/SWIFT_MODULECACHE_PATH и SwiftPM cache/config/security
  в отдельных `/private/tmp/kaban-team2-f1-*`; системные настройки не менялись.
- Хост macOS27.0.1/Xcode27/Swift6.4. Linux CI и macOS26 здесь не запускались.
- Полная suite: **189 XCTest tests, 0 failures, 0 skipped** (baseline 185 + 4):
  KabanProtocol 32 / KabanKit 107 / KabanBoardCore 50. XCTest durations соответственно
  0.062 / 18.773 / 0.078 с; новые 4 теста — 0.001 с, build — 8.55 с.
  Linux CI пока не проверен, macOS измерения не являются его гарантией.

Команда повторения (из корня worktree):

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/kaban-team2-f1-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/kaban-team2-f1-module-cache \
KABAN_SCENARIOS=Scenarios/M1 swift test --disable-sandbox \
  --cache-path /private/tmp/kaban-team2-f1-cache \
  --config-path /private/tmp/kaban-team2-f1-config \
  --security-path /private/tmp/kaban-team2-f1-security
```

`git diff --check` прошёл. В этой задаче visual coverage остаётся отсутствующей
для всех 22 строк таблицы; API-input coverage расширено без утверждения о рендере.

Открытый вопрос Frontend: в какой вехе появляется тестируемая визуальная модель
card/limit/badge/actions, чтобы закрыть именно визуальные требования §3.4?
Подтверждённых production defects этой задачей не найдено; disabled/skip не нужны.
