# F-T2-2 — нагрузочный прогон BoardProjection

Источник: checklist §6.1 F-T2-2, frontend-plan v0.5.36 §5, API origin/main после
PR #8. Только новый Team2ProjectionLoadTests.swift и этот документ; production,
existing tests, resources, Package и CI не менялись.

Snapshot: 10 проектов × 500 задач = 5000 карточек, pipeline на каждый проект.
20 000 последовательных envelopes taskUpdated/taskCreated/projectUpdated выбирают
project/task/state/stage фиксированным LCG seed 0x4B4142414E, без сети. Корпус
генерируется один раз; пять свежих проекций применяют один и тот же поток.
1992 уникальных taskCreated дают final/peak **6992 карточки** во всех пяти прогонах.

Проверяются final/peak count, taskOrder без дублей, seq=20000, отсутствие resync,
последние title/state/stage всех изменённых карточек, project names, одно попадание
каждой task в columns. Reference map создаётся генератором, не читает projection.
Apply loop не сканирует всё состояние после каждого event. Lanes вызывается один
раз в конце каждого прогона, вне benchmark timing. ContinuousClock измеряет только
apply-loop; generation, snapshot init, assertions и lanes вне его. XCTest test
полностью включает эти дополнительные работы. Нет elapsed threshold assertion.
PeakCards — количество карточек, **не RSS**. Не измеряется GUI/layout/XPC throughput.

## Пять измерений

Хост macOS27.0.1/Xcode27/Swift6.4, debug SwiftPM, arm64. Linux CI и macOS26 пока
не выполнялись. Все пять прогонов функционально зелёные.

| Run | apply seconds | per event microseconds | peak cards |
|---|---:|---:|---:|
| 1 | 0.017956541 | 0.898 | 6992 |
| 2 | 0.019081833 | 0.954 | 6992 |
| 3 | 0.017586542 | 0.879 | 6992 |
| 4 | 0.017360333 | 0.868 | 6992 |
| 5 | 0.017582791 | 0.879 | 6992 |

Mean 0.017913608с, worst0.019081833с; это наблюдение этого Mac, не гарантия CI.
Полная suite: **186 XCTest tests, 0 failures/skips** (baseline185 + new1):
Protocol32 (0.059с), Kit107 (19.344с), Board47 (0.538с). Новый пятипрогонный
тест целиком0.468с; build1.32с. git diff --check прошёл.
CI цель <10с пока не подтверждена Linux run; Mac test заметно ниже этой цели.

## Статическое наблюдение о стоимости

replaceCard использует dictionary lookup и append для новых ids. projectUpdated
делает projectOrder.contains, но здесь только 10 проектов. columns(for:) фильтрует
весь taskOrder для каждой стадии каждого проекта: O(projects×stages×tasks) при
одном lanes. Это потенциальная стоимость построения вида, не квадратичная операция
каждого apply. badgeCounts сканирует tasks, feed(for:) — feed; в apply timing они
не входят. Не утверждаем отсутствие bottlenecks без UI-query профилирования.

## Повторение и ограничения среды

Первоначальный standard swift test в F1 не компилировал manifest из-за внешнего
Codex sandbox запрета user module-cache. Разрешённый automatic review запуск ниже
изолирует module/SwiftPM caches/config/security в temp, system настройки не меняет.

```bash
CLANG_MODULE_CACHE_PATH=/private/tmp/kaban-team2-f1-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/kaban-team2-f1-module-cache \
KABAN_SCENARIOS=Scenarios/M1 swift test --disable-sandbox \
  --cache-path /private/tmp/kaban-team2-f1-cache \
  --config-path /private/tmp/kaban-team2-f1-config \
  --security-path /private/tmp/kaban-team2-f1-security
```

Для отдельно нового пятипрогонного benchmark добавить --filter Team2ProjectionLoadTests.
Открытый вопрос Frontend: отдельно измерить full lanes/badge/feed под настоящим UI?
Production defects не найдены; оптимизация production не входила в задачу.
