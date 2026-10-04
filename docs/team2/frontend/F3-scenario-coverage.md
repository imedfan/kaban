# F-T2-3 — аудит replay сценариев M1

Источник: текущие 33 `Scenarios/M1/*.json`, README и `ScenarioReplayTests.swift`
в origin/main после PR #8; свежий frontend-plan v0.5.36 §3.4/§5,
архитектура v0.11.22. Сценарии не менялись. Номера шагов ниже **1-based raw steps**,
включая шаги без then; число snapshots у existing replay может быть меньше.

## Что существующий replay действительно проверяет

`testAllM1ScenariosReplayInAnyEventOrder` читает все 33 файла, для каждого запускает
written/domainFirst/cardsFirst. Это feed/card-event replay, не scheduler/daemon.

- C: `prepare` декодирует полные taskCreated/Updated/Edited, `replay` применяет
  BoardProjection.apply, проверяет полное равенство карточки **с event.data**;
  дополнительно `assertField` проверяет check. Это не независимый then.tasks oracle.
- J: journal domain event → лента, количество/тип + `assertJournalCheck` полей check.
  Проекция не выполняет driver/tick/команды, commandId только pending корреляция.
- E: `prepareEphemeral` → `assertEphemeralCheck`: pipelineDraftValidated и
  modelFlagsChanged; поля check. Не сравнивает отдельные `then.flags` сценария.
- X: commandError → events.count==0, noteCommandError, pending снят;
  **только здесь** `assertPartial` сравнивает then.tasks; знает stage/state/attempt/
  autoRuns/suspiciousFiles, но не retryAt/bounces. В корпусе X — SUSP-03 state.

Все 33 — прочитаны/replayed. Четыре специальных SUSP теста усиливают 01/03/04/05,
но они не делают прочие scenario outcomes полноценно покрытыми. В observed fullrun
не было распечатанных пропусков событий. Unknown/decode skip в existing harness
печатается, а не падает; это постоянный риск ложного положительного результата.

## Добавленное независимое покрытие

`Team2ScenarioCoverageTests.testAllScenarioTaskExpectationsAfterActualCardReplay`
читает те же исходные файлы, строит snapshot из given и применяет реальные полные
card journal events. Затем сравнивает **все then.tasks fields на каждом then шаге**
с карточкой проекции, включая no-event и successful steps. Маппинг только имён:
stage→stageId, autoRuns→runsSinceHuman, bounces→bounceByReason; state/attempt/
retryAt/suspiciousFiles сохраняют смысл. Относительный retryAt разрешается из given
clock + explicit advance; oracle не выводится из event.data.

Это закрывает missing assertions (110 fields), особенно RETRY-01 retryAt,
RETRY-02 bounces, NOCHARGE counters, POOL/WIP states, no-event preservation и
весь SUSP-02. Не копирует private existing replay, его feed/order/ephemeral проверки
не дублирует. Нет фиктивного исполнения backend commands или синтеза taskUpdated
из ожидаемого then.tasks. API visual renderer и backend scheduling отсутствуют.

## Инвентарь всех 33

«New then.tasks steps» — ранее успешные/no-error шаги, пропущенные assertPartial,
теперь проверены новым oracle. X отдельно existing. «Remaining unchecked» —
ожидания вне projection replay: реальные executions/runs, flags без wire event,
refs/filesystem, clone, probes/acceptedFiles; explicit no-then driver шаги не имеют
assertable projection output. full = только доступная projection часть, не весь UC.

| Scenario id | Raw steps | Existing handlers / event types | New then.tasks steps | Remaining unchecked steps/keys | Coverage |
|---|---:|---|---|---|---|
| M1-BOUNCE-01 | 1 | C / taskUpdated | 1 | — | full available projection |
| M1-BOUNCE-02 | 1 | C / taskUpdated | 1 | — | full available projection |
| M1-CANCEL-01 | 1 | C / taskUpdated | 1 | 1: runsKilled,refs | partial backend scope |
| M1-FAIR-01 | 1 | none / no events | — | 1: runsStarted,runningByProject | partial backend scope |
| M1-FLOW-01 | 3 | C,J / taskTransitioned, taskUpdated | 1,2,3 | 2: runsStarted | partial backend scope |
| M1-GIT-01 | 2 | C / taskUpdated | 1,2 | 2: runsKilled | partial backend scope |
| M1-MACPAUSE-01 | 2 | C / taskUpdated | 2 | 1: flags,runsStarted,runsKilled; 2: flags | partial backend scope |
| M1-MAXWH-01 | 3 | C / taskUpdated | 1 | 1: flags; 2: flags; 3: flags | partial backend scope |
| M1-MODELFLAG-01 | 2 | C / taskUpdated | 1,2 | — | full available projection |
| M1-NOCHARGE-daemon_restart | 1 | C / taskUpdated | 1 | — | full available projection |
| M1-NOCHARGE-rate_limit | 1 | C / taskUpdated | 1 | 1: flags | partial backend scope |
| M1-NOCHARGE-runner_auth | 1 | C / taskUpdated | 1 | 1: flags | partial backend scope |
| M1-PAUSE-01 | 2 | C / taskUpdated | 1,2 | 1: runsKilled,runEnd | partial backend scope |
| M1-PIPE-01 | 3 | C / taskUpdated | 2,3 | 1: flags,runsKilled; 2: runsStarted; 3: flags | partial backend scope |
| M1-PIPE-02 | 1 | E / pipelineDraftValidated | — | — | full available projection |
| M1-POOL-01 | 1 | C / taskUpdated | 1 | — | full available projection |
| M1-POOL-02 | 1 | none / no events | 1 | 1: runsStarted,runsKilled | partial backend scope |
| M1-RATE-01 | 5 | none / no events | 2,5 | 1: flags; 2: flags; 3: flags; 4: flags | partial backend scope |
| M1-RETRY-01 | 6 | C / taskUpdated | 1,2,3,4,5,6 | — | full available projection |
| M1-RETRY-02 | 4 | C / taskUpdated | 1,2,4 | 3: no then (driver/tick only) | partial backend scope |
| M1-RETRY-03 | 3 | C / taskUpdated | 1,3 | 1: clone; 2: no then (driver/tick only); 3: clone,refs | partial backend scope |
| M1-RUNLIMIT-01 | 1 | C / taskUpdated | 1 | 1: runsStarted | partial backend scope |
| M1-RUNLIMIT-02 | 2 | C / taskUpdated | 1,2 | — | full available projection |
| M1-SILENT-01 | 2 | C / taskUpdated | 1 | 1: probes; 2: probes | partial backend scope |
| M1-SUBST-01 | 2 | C,E / taskUpdated, modelFlagsChanged | 1,2 | — | full available projection |
| M1-SUSP-01 | 3 | C,J / suspiciousFilesAccepted, suspiciousFilesFound, taskUpdated | 1,2 | 2: runsStarted; 3: no then (driver/tick only) | partial backend scope |
| M1-SUSP-02 | 1 | C,J / suspiciousFilesFound, taskUpdated | 1 | — | full available projection |
| M1-SUSP-03 | 1 | X / no events | — | — | full available projection |
| M1-SUSP-04 | 3 | C,J / suspiciousFilesFound, taskUpdated | 1,2,3 | 1: acceptedFiles | partial backend scope |
| M1-SUSP-05 | 1 | C,J / suspiciousFilesAccepted, taskUpdated | 1 | — | full available projection |
| M1-WIP-01 | 1 | C / taskUpdated | 1 | 1: runsStarted | partial backend scope |
| M1-WIP-02 | 3 | C,J / humanRequested, taskUpdated | 1,2,3 | — | full available projection |
| M1-WIP-03 | 2 | C / taskUpdated | 1,2 | 2: runsStarted | partial backend scope |

## Приоритетные пробелы / вопросы

1. FAIR-01, MACPAUSE/PIPE/RATE: значительная часть заявленного поведения — scheduler
   и flags без wire events; существующий тест может лишь не бросить исключение.
   Нужно backend replay или новые event fixtures от Analyst, не client state logic.
2. CANCEL/PAUSE/RETRY-03: runsKilled, refs/clone и end reason не проверяются BoardCore.
   Это процесс/восстановление демона, а не проекция; предмет отдельного backend suite.
3. SUSP-04 acceptedFiles — история TaskDetail, не BoardProjection; проверяется факт
   сохранения текущего списка, но история принятия требует client/detail API tests.
4. Unknown/decode skipped events стоит сделать отдельным строгим coverage gate после
   решения основной команды. Existing file не меняли; подтверждённого production
   дефекта здесь нет, поэтому issue/skip нового теста не нужны.

Первый targeted run выявил только ошибку нового oracle: строки +30s/+2m сначала
сравнивались с абсолютным retryAt без advance-clock. Исправлено в новом тесте;
это не ошибка production/scenario. Linux CI и macOS26 здесь не выполнялись.

## Проверки

Полная suite повторяет KABAN_SCENARIOS=Scenarios/M1 swift test с approved outer
sandbox bypass --disable-sandbox и всеми module/SwiftPM caches/config/security
в /private/tmp/kaban-team2-f1-* (как F1). Обычный запуск под внешней Codex sandbox
ранее не компилировал manifest из-за denied user module-cache; профиль macOS
и системные настройки не менялись. Хост macOS27.0.1/Xcode27/Swift6.4.
Полная suite: **186 XCTest tests, 0 failures/skips** (baseline185 + new1):
Protocol32 (0.062с), Kit107 (20.005с), Board47 (0.114с).
New oracle110 field assertions /33scenarios — 0.040с; build0.73с.
Existing replay3orders тоже прошёл, сообщений skipped не было.
`git diff --check` прошёл. Проверка visual/backend поведения остаётся вне scope.
