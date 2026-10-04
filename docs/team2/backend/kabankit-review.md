# B1 — независимый аудит KabanKit

Дата 2026-10-04; ветка `team2/backend-b1-audit`, база `origin/main` `1d647ea`. Прочитаны свежие snapshots spec v0.8.24, architecture v0.11.22, decisions-log; более ранняя v0.11.21 из checklist не использовалась вместо обновлённого источника. Проверены Sources/KabanKit Pipeline/YAML/Git/StateMachine/Support и соответствующие существующие тесты. Skill: diff-impact-reviewer-global, применён с расширенной областью, явно заданной B1. Уверенность высокая для подтверждённых находок, средняя для вопросов интеграции.

## Подтверждённые расхождения

| Требование / цитата | Код (baseline file:line) / фактическое поведение | Серьёзность | Предложение / issue |
|---|---|---|---|
| Spec §4.1: `max_file_mb > 0 без верхней границы`; UC-25: «файл … больше max_file_mb» | PipelineParser.swift:288 принимает finite `1e20`; PipelineValidator.swift:128 проверяет только >0; PipelineConfig.swift:119 преобразует bytes в Int64 с trap; SuspiciousFiles.swift:26 вызывает это при обычном файле | major: валидный pipeline приводит к process trap при scan | Сохранить обещание отсутствия верхней границы и сделать безопасное сравнение/насыщение либо согласовать новую границу. [#37](https://github.com/imedfan/kaban/issues/37) |
| Spec UC-04: «retry_wait: readonly_violation»; arch §6.1: «попытка списывается, паузы как у gate_failed» | TaskMachine.swift:389 вызывает chargeAttempt(reason:.gateFailed); первый readOnlyChanges → retry_wait: gate_failed. Existing TaskMachineTests.swift:365 закрепляет gateFailed. Protocol TaskState.swift:59 уже имеет readonlyViolation | major: неправильная причина в карточке/ленте и scheduleRetry | Передавать readonlyViolation при сохранении backoff/attempt logic; уточнить ожидание существующего теста. [#36](https://github.com/imedfan/kaban/issues/36) |
| Spec UC-01: «перенос строки и NUL проверяются до обрезки» | GitIdentity+Project.swift:72 сравнивает Character с отдельными CR/LF; CRLF является одной графемой и проходит explicit/repository validation | major: недопустимый author | Валидировать scalar/byte CR/LF/NUL; обновить owned tests. [#30](https://github.com/imedfan/kaban/issues/30), B4 regression |
| Spec §1.5 foreign_refs: «checkout -B, switch -C» | GitPolicy.swift:95–98 → shortCluster:117–120 принимает только alphabetic cluster; attached `-Btask1`/`-Ctask1` пропускает. В B3 real Git сбрасывает существующий чужой ref | major: static filter gap | Разбирать argv option/value по Git grammar. [#23](https://github.com/imedfan/kaban/issues/23), не дублируется |
| Spec §1.5: запрет удаления/движения веток | GitPolicy.swift:92–94 проверяет exact `--delete`/`--move`; real Git принимает `branch --del other`, `branch --mov other renamed` | major: static filter gap | Учесть поддерживаемые Git long-option abbreviations. [#24](https://github.com/imedfan/kaban/issues/24) |
| Spec §1.5: «rebase на main в любой записи» | GitPolicy.swift:100 / namesMain:122–125 не разбирает `--onto=main`; permissive policy разрешает его, real Git выполняет | major: static filter gap | Разбирать equals-form target. [#25](https://github.com/imedfan/kaban/issues/25) |

Пути в таблице относительны `Sources/KabanKit/`: Pipeline* — папка Pipeline, Git* — Git, TaskMachine — StateMachine. Existing test и protocol paths указаны отдельно. Статический Git matcher — только один слой: issues #23–25 не доказывают обход Seatbelt, runtime `/git/check` или production exploitation.

### Воспроизведения новых находок

Во внешней `/private/tmp/kaban-team2-context/B1-boundary.swift` сохранён transient harness, связанный с библиотеками из успешного B4 build. Он не добавлен в repo. Вход (обычный валидный pipeline Backlog→Dev→Merge→Done с explicit model) включает:

```yaml
suspicious_files:
  max_file_mb: 1e20
```

`PipelineValidator.validate(yaml:)` печатает `validation valid=true, issues=[]`. `SuspiciousFilesScanner.scan([ChangedFile(path: "ordinary.txt", sizeBytes: 1, blob: "synthetic")], policy: config.suspiciousFiles)` в отдельном subprocess завершается exit 133: `Double value cannot be converted to Int64 because the result would be greater than Int64.max`. Core dumps выключены только в subprocess shell через ulimit; журнальный файл `/private/tmp/kaban-team2-context/B1-size-trap.log`. Ни suite, ни агентский процесс не падали. Минимальный equivalent typed reproducer после импорта KabanKit:

```swift
let policy = SuspiciousFilesPolicy(maxFileMB: 1e20)
_ = SuspiciousFilesScanner.scan(
    [ChangedFile(path: "ordinary.txt", sizeBytes: 1, blob: "synthetic")],
    policy: policy)
```

Проверенный YAML harness важен: показывает, что scanner получает опасное значение через успешную валидацию, а не только через вручную созданный unchecked policy.

Тот же harness без scan строит read-only agent stage с тремя попытками, проходит `start → completeStage → gatesPassed → resultChecked(.readOnlyChanges)` и печатает `retryWait(gateFailed), attempts=1`. Требуемая причина — readonlyViolation. Второе нарушение в owned test уже приводит к invalidResult; этот путь не объявляется сломанным.

## Проверено без подтверждённого расхождения

| Требование | Реализация / существующее покрытие |
|---|---|
| Нет модели по умолчанию; auto/placeholder блокируют pipeline | PipelineTemplate + PipelineValidator.swift:378–413; PipelineValidatorTests: template/no-model/placeholder/auto |
| Таблица ValidationCode §4.1, severity, params | PipelineParser IssueSink, PipelineValidator range/checkGitRule; ValidationParamsTests: keys, representative params, yaml line, roundtrip. Полная сверка документа и enum — AN4, не дублируется |
| Ровно queue/merge, terminal reachable, on_success cycle, active stage removal | PipelineValidator.swift:153–174, 353–376; PipelineValidatorTests graph/kind/activeTasks |
| Только writable agent return, no_return_target/unknown_stage, defaults | PipelineConfig.swift:37–74, 173–195; PipelineValidator.swift:237–289/347; ReturnRulesTests |
| Preset→project→stage, sticky deny, source последнего изменения решения | GitPolicyResolver.decide/resolve; GitAndFilesTests sourceChains/deny/decide/wordPrefix |
| Семь hardInvariants в порядке; readonly narrowing; unknown extend только warning | GitPolicy.swift hardInvariants, resolve readonly blocks; GitAndFilesTests hardIds/readonly unknown dedup/narrowing; пробелы matcher перечислены выше |
| Charged attempts, run refunds, лимит запуска, human reset | TaskMachine start/runEnded/chargeAttempt/human; TaskMachineTests retry/noncharging/runLimit/substitution/probe; PropertyTests determinism/invariants |
| Gate on_fail и merge on_conflict не повторяют gate на месте | TaskMachine gatesFailed/mergeConflictOrRedGates/bounce; ReturnRulesTests, TaskMachineTests mergeConflict |
| waiting_human, stale run id, incident human resolution | TaskMachine checkRun/leaveWaiting; TaskMachineTests staleCalls/questionAnswer/incident |
| Suspicious path+blob, accepted changed blob re-triggers, stale set | SuspiciousFiles scan/sameSet; SuspiciousFilesMachineTests exact/stale/recheck/answer/requestChanges/merge |
| Author one-shot normal registration config, daemon hardened environment | GitIdentity+Project.swift:30–49/126–140; DaemonGit.swift:48/81; DaemonGitTests plus отдельная B4 ветка |

## Требования без достаточного теста / ограничения

Это список конкретных пробелов, а не заявление, что весь соответствующий модуль не протестирован. Проверен main baseline; B2–B4 tests живут в отдельных ветках, пока координатор не опубликовал их.

- CRLF identity обеих полей и explicit/repository: owned main tests проверяют отдельные CR/LF/NUL, но не CRLF-графему. B4 добавляет regression #30.
- `max_file_mb` finite выше Int64-byte capacity: Validator/Files tests используют обычные пороги; ни успешная валидация огромного значения, ни безопасный scanner результат не покрыты. Подтверждённый crash описан выше; trap нельзя запускать внутри обычного XCTest process.
- First readonly violation с правильным wire reason: тест есть, но утверждает противоречащее документам gateFailed (#36).
- Git supported option grammar: attached digits/abbreviations/equals-form target отсутствуют в owned matcher тестах; B3 покрывает #23–25 с conditional skip.
- Runtime `/git/check` target scope для reset/rebase/fetch/notes/worktree, `.kaban` paths, foreign base/ref snapshots: KabanKit содержит pure policy helpers, не runtime enforcement. Это задачи KabanGit/KabanDaemonCore; для них интеграционного доказательства здесь нет.
- Atomic journal+persistence+effects, перезапуск с DB, actual process group termination, quota/cooldown scheduling, Human WIP admission: pure TaskMachine возвращает effects, но не исполняет их. Package.swift явно оставляет KabanDaemonCore/GRDB отдельному PR; отсутствие этих integration tests не объявляется багом KabanKit.
- isText для suspicious file diff: ChangedFile не несёт текстовый признак, Scanner возвращает DTO default; правило определения через git numstat остаётся на интеграционном слое. Уточнить, где заполняется признак до event/card.

## Вопросы, не ошибки

1. Уже заведённые spec contradictions #9 (answerHuman on non-agent), #10 (`.kaban` rollback vs incident), #11 (Human WIP), #12 (root type_mismatch empty path) оставлены владельцам документов. Architecture v0.11.22 уже явно ограничивает answerHuman agent stage; код ему соответствует.
2. `PipelineValidator.validate(config:)` применяет semantic checks, но не parser-only `version != 1` и finite Double checks. Должна ли typed config API гарантировать такую же защиту, как YAML path, или caller обязан гарантировать структурную валидность? Пока это вопрос контракта, не отдельный issue.
3. firstWritableAgentStage fallback на order массива, если нет writable stage в entry chain: применён и к invalid draft. Нужна ли обязательная connectedness всех стадий к entry? Документы требуют terminal reachability, не явную единственную entry-connected chain; без решения не объявляем ошибкой.

## Доставка и проверка

Новый файл только `docs/team2/backend/kabankit-review.md`; существующие файлы не менялись. B1 не добавляет тесты и не требует нового полного suite: production unchanged, ранее подтверждён full B4 run exit0 на том же source baseline. Read-only audit + transient isolated harness, Swift 6.4 / macOS arm64. Linux CI этой ветки не запускался; локальный коммит без push/PR/merge. Публикацию и issues выполняет координатор.
