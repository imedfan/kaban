# Backend-задачи Kaban MVP

Очередь поручена Артёмом 5 октября 2026 и перенесена из приложенного
`backend-mvp-tasks.md`. Объём и зависимости BE-01–20 сохраняются.

Срез 6 октября 2026, база `origin/main` `ea02f0c`: BE-01–04 приняты в main в PR #71–74.
BE-05 выполнен и принят в main в [PR #76](https://github.com/imedfan/kaban/pull/76) (`ea02f0c`); границы — [исполнение эффектов](backend-effect-execution-2026-10-06.md).
BE-06 выполнен в [PR #77](https://github.com/imedfan/kaban/pull/77), влитом в `codex/be-05-effect-execution` и ещё не принятом в main; границы — [клоны задач](backend-task-clones-2026-10-06.md).
BE-08 выполнен в [PR #78](https://github.com/imedfan/kaban/pull/78), влитом в `codex/be-06-task-clones` и ещё не принятом в main; границы — [управление процессами](backend-process-control-2026-10-06.md).
BE-07 выполнен в [PR #79](https://github.com/imedfan/kaban/pull/79), открытом поверх #78 и ещё не принятом в main; границы — [драйвер Cursor CLI](backend-cursor-driver-2026-10-06.md).
BE-14 выполнен в [PR #80](https://github.com/imedfan/kaban/pull/80), открытом поверх #79 и ещё не принятом в main; остановка до первого инструмента не проверена; границы — [каталог моделей](backend-model-catalog-2026-10-06.md).
BE-09–13 и BE-15–20 ещё не завершены. Наличие DTO/fixtures не является реализацией последующих задач.
Мерж выполняет Артём; следующий связный инкремент — BE-15.


## BE-01. Расширить wire-контракты демона

**Статус:** выполнено; [PR #71](https://github.com/imedfan/kaban/pull/71) принят в main.

**Приоритет:** P0

**Зависимости:** PR #70 (принят)

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-12, UC-13, UC-20; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanProtocol/Commands.swift`; `Sources/KabanProtocol/DaemonTransport.swift`; `Sources/KabanProtocol/Events.swift`; `Sources/KabanProtocol/AgentEvent.swift`; `Sources/KabanTransport/DaemonClient.swift`.

### Описание

- Добавить совместимые DTO и операции для замещающего snapshot, состояния соединения,
  эфемерных событий, чтения логов, черновика пайплайна и настройки окружения Cursor.
- Определить способ передачи проверенного YAML для `updatePipeline(contentHash)`:
  черновик на сервере, привязанный к проекту, либо совместимая операция передачи;
  проверять актуальность и hash содержимого.
- Добавить типизированную команду восстановления WIP; перечислить поддержанные
  и неподдержанные команды. Не скрывать недоступность через успешный пустой ответ.
- Обновить архитектуру §5 и protocol fixtures вместе с KabanProtocol.

### Критерии приёмки

- [x] legacy snapshots/commands/details декодируются; неизвестные поля допустимы, malformed известные отклоняются.
- [x] Замещающий snapshot согласован по seq; эфемерным событиям не присваивается durable seq.
- [x] Draft другой версии/проекта не применяется.
- [x] Для каждой новой операции есть fixtures запроса, ответа, события и отказа.

## BE-02. Реализовать подключение, удаление и переподключение локальных проектов

**Статус:** выполнено; [PR #72](https://github.com/imedfan/kaban/pull/72) принят в main.

**Приоритет:** P0

**Зависимости:** BE-01

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-01, UC-14; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanDaemonCore/StoreCommands.swift`; `Sources/KabanKit/Git/GitIdentity+Project.swift`; `Sources/KabanKit/Pipeline/PipelineTemplate.swift`.

### Описание

- Реализовать `addProject/removeProject/relinkProject/listBranches/detectGates`,
  обработку автора коммитов, долговечные метаданные проекта и наблюдение отсутствующей папки.
- Проверять git-репозиторий, канонический путь и повтор регистрации, наличие локального `main`;
  для другой базовой ветки дать явную диагностику, не переключать её молча.
- Шаблон добавляет только `.kaban/`; незакоммиченные файлы пользователя не включаются в коммит.
  Отсутствующий/невалидный pipeline не мешает хранить задачи в Backlog.
- При удалении проекта определить и документировать согласованный lifecycle
  активных runs/клонов/истории; пользовательский репозиторий не удалять.

### Критерии приёмки

- [x] non-git и `identity_required` не оставляют полупроекта; отказ содержит правильные `missing/invalid` params.
- [x] Dirty checkout сохраняется.
- [x] Повтор commandId не регистрирует второй проект.
- [x] Missing path останавливает новые запуски; relink сохраняет projectId.
- [x] Project events и snapshot согласованы после reopen.

## BE-03. Реализовать хранение, валидацию и применение пайплайна

**Статус:** выполнено; [PR #73](https://github.com/imedfan/kaban/pull/73) принят в main. Проверки и границы — [отчёт BE-03](backend-pipeline-storage-2026-10-05.md).

**Приоритет:** P0

**Зависимости:** BE-01, BE-02

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-13, UC-19, UC-23, UC-24; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/Pipeline/`; `Sources/KabanDaemonCore/StoreCommands.swift`; `Sources/KabanDaemonCore/EngineModels.swift`.

### Описание

- Использовать существующие parser/validator/resolver, хранить версии и читать закоммиченный
  `main:.kaban/` как источник. Реализовать `validatePipeline`, `updatePipeline` и применение ручных правок.
- Поддержать произвольные допустимые stage kinds, stage skills, gates/hooks,
  limits/returns, git/suspicious-files настройки и resolved draft policy.
- Сохранение создаёт отдельный коммит только `.kaban/`, с проверкой hash и базовой версии
  и восстановлением незавершённого файлового эффекта; не терять пользовательские правки.
- Текущий run использует зафиксированный RunSpec; новые настройки действуют
  со следующего run. Не удалять стадии с нетерминальными задачами.

### Критерии приёмки

- [x] отсутствующая модель/Auto/нет merge/нет пути Done/неверная return target не применяются.
- [x] Ошибки имеют paths; warnings MCP не блокируют сохранение.
- [x] Manual invalid main поднимает pipeline_invalid: текущие runs доигрывают, новые не стартуют.
- [x] Hash race, WIP shrink и reload проверены; fake exception не расширяется.

## BE-04. Расширить планировщик на полный пайплайн и запустить цикл в демоне

**Статус:** выполнено; [PR #74](https://github.com/imedfan/kaban/pull/74) принят в main. Проверки и границы — [отчёт BE-04](backend-full-scheduler-2026-10-05.md).

**Приоритет:** P0

**Зависимости:** BE-02, BE-03

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-03, UC-06, UC-11, UC-14; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanDaemonCore/StoreScheduler.swift`; `Sources/KabanDaemonCore/StoreSchedulerFlags.swift`; `Sources/KabanDaemon/DaemonMain.swift`.

### Описание

- Расширить существующий scheduler для gate/merge/terminal и production projects;
  запустить ограниченный wake/tick loop в host, без busy loop и fake-only фильтров.
- Учитывать global/project agent slots, execution WIP, human admission,
  waiting_human intake, очередь merge и авторитетные scheduler/model/quota flags.
- Сохранить returned/answered → priority → FIFO, weighted fairness и обход
  неподходящего кандидата. Таймер retry не удерживает DB transaction.

### Критерии приёмки

- [x] при ceiling=3 четвёртый agent не запускается; два проекта не голодают.
- [x] Gate/human/merge имеют правильный тип capacity и не списывают agent slot как новый агент.
- [x] Уменьшение лимита не вытесняет задачи.
- [x] Manual pause не убивает текущие runs; human admission marker переживает pause/reopen.
- [x] Concurrent ticks не превышают лимиты.

## BE-05. Реализовать исполнение внешних эффектов с claim, lease и receipt

**Статус:** выполнено; [PR #76](https://github.com/imedfan/kaban/pull/76) принят в main (`ea02f0c`). Проверки и границы — [отчёт BE-05](backend-effect-execution-2026-10-06.md).

**Приоритет:** P0

**Зависимости:** BE-01

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-03, UC-10, UC-12; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanDaemonCore/StoreEffects.swift`; `Sources/KabanDaemonCore/StoreEngineSchema.swift`; `Sources/KabanDaemonCore/EngineModels.swift`.

### Описание

- Добавить API исполнителя реальных эффектов поверх существующих effect IDs и outbox:
  claim/lease, ownership/fencing, live result и receipt.
- Проверять актуальность task/stage/run перед побочным действием и принятием
  результата. Исполнение process/git идёт после commit, вне SQLite transaction.
- Добавить additive migration; сохранять исходный payload без изменений и диагностику незавершённого
  эффекта. Не использовать `deliverFake` для настоящих результатов.

### Критерии приёмки

- [x] два workers не запускают один effect; crash до/после external action восстанавливается через сверку фактов и receipt, без обещания exactly-once процесса.
- [x] Superseded/old lease результат не воскрешает отменённую задачу; повтор receipt идемпотентен, другой payload даёт конфликт.
- [x] DB failure не оставляет полуперехода.

## BE-06. Реализовать создание и очистку рабочих клонов задач

**Статус:** выполнено; [PR #77](https://github.com/imedfan/kaban/pull/77) влит в `codex/be-05-effect-execution`, ещё не принят в main. Проверки и границы — [отчёт BE-06](backend-task-clones-2026-10-06.md).

**Приоритет:** P0

**Зависимости:** BE-02, BE-05

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-03, UC-10, UC-11; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/Git/DaemonGit.swift`; `Sources/KabanDaemonCore/StoreEffects.swift`.

### Описание

- Создавать `git clone --local` и ветку задачи от актуального `main`; сохранять путь клона и базовый коммит;
  один клон на задачу, отдельный `fresh-readonly` при соответствующей настройке.
- Использовать существующий DaemonGit, identity, hooks/fsmonitor suppression,
  очищенное окружение. Портовый диапазон, temp/DerivedData относятся к задаче.
- Реализовать отложенную очистку и архивную ветку по `keepBranch`, безопасную проверку
  принадлежности пути перед удалением. WIP save/restore — в BE-18/19.

### Критерии приёмки

- [x] параллельные задачи имеют разные refs/config/cwd; основная копия пользователя не изменяется агентом.
- [x] Частично созданный клон не приводит к двойному run после reopen.
- [x] Cancel сохраняет архив по выбору, cleanup не удаляет чужой путь.

## BE-07. Реализовать и проверить драйвер Cursor CLI

**Статус:** выполнено; [PR #79](https://github.com/imedfan/kaban/pull/79) открыт поверх #78, ещё не принят в main. Проверки и границы — [отчёт BE-07](backend-cursor-driver-2026-10-06.md).

**Приоритет:** P0

**Зависимости:** BE-01

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-04, UC-20, UC-22, UC-24; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanProtocol/AgentEvent.swift`; `research/cursor-agent-cli.md`; `spikes/backend/`.

### Описание

- Довести [spike 1](https://github.com/imedfan/kaban/blob/8d992e6/research/cursor-agent-cli.md) до обезличенных реальных
  fixtures установленной версии: stream, stderr/exit, model catalog, resume,
  model init, login under launchd, MCP discovery и timeout.
- Реализовать AgentDriver/CursorCLIDriver с argv/env/cwd, явным model,
  нормализацией AgentEvent, version/capability checks и runner check/recheck.
- Prompt = skill + задача/критерии + handoff + return/gate замечания + grants
  + правила финального MCP-вызова. Skill content берётся из выбранной версии pipeline.
- Auth через поддерживаемый способ; Keychain/env без ключей в argv, prompt, БД или логах.

### Критерии приёмки

- [x] неизвестное stream-событие не ломает run, partial lines корректны, malformed/слишком большая строка ограничена.
- [x] Model обязательна.
- [x] Без проверенного resume стартует новая сессия с сохранённым контекстом, без выдуманного sessionId.
- [x] Не найден/не залогинен → runner_unavailable, проверка каждые 5 мин и по кнопке.
- [x] Версия CLI и фактические ограничения зафиксированы; проверка help не заменяет реальный запуск.

## BE-08. Реализовать управление процессами агентов и технические ретраи

**Статус:** выполнено; [PR #78](https://github.com/imedfan/kaban/pull/78) влит в `codex/be-06-task-clones`, ещё не принят в main. Проверки и границы — [отчёт BE-08](backend-process-control-2026-10-06.md).

**Приоритет:** P0

**Зависимости:** BE-05, BE-06, BE-07

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-10, UC-11, UC-12; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/StateMachine/TaskMachine.swift`; `Sources/KabanDaemonCore/StoreEffects.swift`; `Sources/KabanDaemonCore/StoreDetail.swift`.

### Описание

- Запускать агент в отдельной группе процессов; сохранять PID, идентификатор старта, состояние run,
  timestamps/session, stdout/stderr, inactivity и общий timeout.
- Пауза задачи, перенос назад и отмена останавливают только группу процессов этой задачи;
  stop/kill эффекты выполняются идемпотентно и не принимают поздний результат.
- Реализовать учёт повторов после crash/hang/no_final_call: 3 попытки с паузами 30 с и 2 мин;
  грязный WIP перед rollback, сохранение клона после gate_failed/no_final_call.

### Критерии приёмки

- [x] технический exit 0 сам не завершает стадию; без final MCP идёт no_final_call, а молчаливый run отдельно классифицируется BE-15.
- [x] Попытки/autoRuns не списываются за manual stop, daemon restart, auth/limit/substitution.
- [x] Run с descendants останавливается целиком; timeout не блокирует daemon/XPC.

## BE-09. Реализовать MCP-сервер доски

**Приоритет:** P0

**Зависимости:** BE-01, BE-05

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-04, UC-05, UC-06; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/StateMachine/TaskMachine.swift`; `Sources/KabanDaemonCore/DurableCommand.swift`; `Sources/KabanDaemonCore/StoreDetail.swift`.

### Описание

- Выбрать HTTP/MCP библиотеку и реализовать пять инструментов:
  get_task_context, report_progress, complete_stage, return_to_stage, request_human.
- Сервер доступен только на `127.0.0.1`; token передаётся через env и привязан к task/project/stage/run;
  revocation и bounded payloads. MCP mutations используют reducer/journal.
- Progress обновляет время последней активности и публикует данные задачи; summary/issues/questions/artifacts
  сохраняются долговечно. Повтор финального вызова имеет явную идемпотентность.

### Критерии приёмки

- [ ] чужой/отозванный token и stale run не меняют задачу; агент не подменяет target taskId.
- [ ] Duplicate completion не создаёт второй переход.
- [ ] Нелегальная return target отклонена; request_human освобождает execution slot; final call запускает проверки, а не напрямую выставляет следующую стадию/Done.
- [ ] Notices доставляются адресно.

## BE-10. Реализовать проверку MCP-конфигурации и изоляцию запуска

**Приоритет:** P0

**Зависимости:** BE-06, BE-07, BE-09

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-18, UC-24; `docs/architecture-v0.md`.

**Код и материалы:** `research/mcp-config-isolation.md`; `research/macos-seatbelt.md`; `Sources/KabanKit/Git/DaemonGit.swift`.

### Описание

- Довести [MCP isolation](https://github.com/imedfan/kaban/blob/8d992e6/research/mcp-config-isolation.md) и
  [Seatbelt research](https://github.com/imedfan/kaban/blob/8d992e6/research/macos-seatbelt.md) до воспроизводимой проверки
  установленного CLI. Отдельный run HOME не должен терять поддерживаемую авторизацию.
- По умолчанию подключать только сервер доски; стадии получают только выбранные серверы из белого списка.
  Проверять конфиги, source/endpoint collisions, parent/global/plugins в том же окружении.
- Собирать конфигурацию каждого run, token передавать только через `${env:KABAN_RUN_TOKEN}`; восстановить MCP-файл
  до result check и при recovery. Seatbelt защищает исходный repo, .kaban,
  git config/hooks/info и чувствительные каталоги; сеть согласно принятой политике.

### Критерии приёмки

- [ ] unexpected/неразрешимый MCP preflight блокирует run, не одобряет всё молча; disabled selected server даёт warning.
- [ ] Подмена файла не остаётся в diff.
- [ ] Проверены прямой /usr/bin/git и прямые записи, а не только shim.
- [ ] Auth/сборка/MCP работают в реальном профиле.
- [ ] Непроверенная изоляция не выдаётся за гарантированную; остаточный риск CLI token явно описан по архитектуре §13.

## BE-11. Реализовать гейты, hooks и передачу результатов между стадиями

**Приоритет:** P0

**Зависимости:** BE-04, BE-05, BE-06, BE-07, BE-08, BE-09, BE-10

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-04, UC-05, UC-07, UC-19; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/StateMachine/TaskMachine.swift`; `Sources/KabanKit/Git/DaemonGit.swift`; `Sources/KabanDaemonCore/StoreEffects.swift`.

### Описание

- Запускать детерминированные commands/gates и on_enter/on_exit hooks с
  timeout, cwd/env, captured outputs и replay-safe effect semantics.
- `complete_stage` → gating → result check → commit → следующий stage;
  standalone gate и его on_fail разрешаются по существующему валидатору.
- Сохранять stage summaries, gate output, diffstat/commits и return issues
  для следующей роли; Strict коммитит демон, Standard/Free — страховочный commit.
- Read-only changes проверять по фактам, откатывать; второе нарушение за заход
  переводит в invalid_result. Соблюдать pair/total bounce/run limits.

### Критерии приёмки

- [ ] зелёный exit без final call не заменяет MCP.
- [ ] Красный stage gate повторяет тот же stage/клон; красная отдельная gate-стадия возвращает в resolved coding target.
- [ ] Test → Dev передаёт конкретные issues, новый заход сбрасывает attempts.
- [ ] После replay нет второго commit/hook; полный pipeline доходит до Human Review.

## BE-12. Реализовать git-обёртку и разовые разрешения

**Приоритет:** P1

**Зависимости:** BE-03, BE-05, BE-09, BE-10

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-17, UC-19; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/Git/GitPolicy.swift`; `Sources/KabanProtocol/DurableDetails.swift`; `Sources/KabanProtocol/Events.swift`.

### Описание

- Реализовать KabanGitShim и `/git/check` поверх существующего policy evaluator;
  final policy = preset/project/stage/conditional/grants с hard invariants.
- Реализовать allowGitOnce/addDenialToPolicy/revokeGitGrant и notices delivery;
  deny/grant/delivered/consumed/revoked/expired читать из durable details.
- Демон недоступен → отказ; 5 отказов за run → ожидание человека.

### Критерии приёмки

- [ ] разрешение однократно и адресно, повтор запроса не расширяет scope; hard invariants grant не отменяет.
- [ ] Условный override проверяется сервером.
- [ ] Delivered не равен consumed, unknown reason не теряет payload.
- [ ] После done/cancel grants истекают.
- [ ] CLI deny-rules не перехватывают настраиваемый запрет раньше shim.

## BE-13. Реализовать проверку результата, подозрительных файлов и инциденты

**Приоритет:** P0

**Зависимости:** BE-03, BE-05, BE-06, BE-10

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-18, UC-25; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/Git/SuspiciousFiles.swift`; `Sources/KabanKit/StateMachine/TaskMachine.swift`; `Sources/KabanDaemonCore/StoreDetail.swift`.

### Описание

- Проверять protected refs/tags/config/.kaban и read-only diff по всей task branch;
  учесть untracked, symlinks, большие файлы и Strict uncommitted changes.
- Реализовать durable incident list/resolution, rollback и authoritative counts;
  listIncidents и acceptSuspiciousFiles с path+blob проверкой.
- Resume после принятия актуального набора продолжает отложенный переход без
  нового run; отдельное действие человека закрывает incident.

### Критерии приёмки

- [ ] `incidentOpened/Resolved` и `projectUpdated` атомарны.
- [ ] Snapshot/detail переживают journal retention.
- [ ] Stale file set отклонён; изменённый blob проверяется снова. answerHuman/requestChanges не принимают набор; retry/move/cancel применяют ровно правила UC-25.
- [ ] Никакого автоматического продолжения после hard-invariant incident.

## BE-14. Реализовать каталог моделей и проверку подмены модели

**Статус:** выполнено; [PR #80](https://github.com/imedfan/kaban/pull/80) открыт поверх #79, ещё не принят в main. Остановка до первого инструмента не проверена. Границы — [каталог моделей](backend-model-catalog-2026-10-06.md).

**Приоритет:** P0

**Зависимости:** BE-03, BE-07, BE-08

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-22, UC-23; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanProtocol/Models.swift`; `Sources/KabanProtocol/Commands.swift`; `Sources/KabanProtocol/AgentEvent.swift`; `Sources/KabanProtocol/Quota.swift`.

### Описание

- Реализовать listModels/refresh, model pool rules, persistent catalog, проверки
  при запуске и раз в сутки; новую модель помечать «проверь пул».
- Реализовать task/stage override только на явную модель, clearModelFlag;
  исчезнувшая модель блокирует только связанные стадии.
- Requested id/name сверять с init actual name; несовпадение останавливает run
  и создаёт durable requested/actual/fallback диагностику без списания.

### Критерии приёмки

- [x] Auto отвергается в API/YAML; override не меняет другие задачи.
- [x] Неизвестное/неоднозначное actual имя → model_unconfirmed, без выдуманного совпадения.
- [ ] Проверить экспериментом, доступна ли остановка до первого инструмента; если CLI не даёт такой гарантии, зафиксировать расхождение и требуемый способ реализации.
- [x] Подмена не принимается как успешный результат, Флаги и счётчики доступны после повторного подключения.

## BE-15. Реализовать обработку лимитов Cursor и проверочные запуски

**Приоритет:** P1

**Зависимости:** BE-04, BE-07, BE-08, BE-14

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-09, UC-20; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanProtocol/SchedulerFlags.swift`; `Sources/KabanProtocol/TaskState.swift`; `research/cursor-agent-cli.md`.

### Описание

- Классифицировать ошибки по реальным обезличенным fixtures: rate_limit, usage_exhausted cm/om/unknown,
  model_unavailable, runner_auth, silent_exit; unknown errors остаются явной диагностикой.
- Cooldown 15/30/60 мин, reset dates, pool/model scope, resumeAfterRateLimit/recheck;
  сохранять применимые flags и проверять eligibility перед каждым start.
- Silent exit probe одна на модель, не чаще 10 мин; reset неизвестен — 6 ч.
  Проверка не превращается в бесконечный платный loop.

### Критерии приёмки

- [ ] текущие другие runs доигрывают; только ошибочный run освобождается по правилам.
- [ ] Om flag не блокирует Cm; unknown usage блокирует весь Мак.
- [ ] Не списываются attempts/autoRuns.
- [ ] Перезапуск не сбрасывает cooldown; eligible task не стоит за заблокированной.
- [ ] `quota=nil` не означает 100% свободно.

## BE-16. Реализовать долговечную историю запусков и чтение логов

**Приоритет:** P0

**Зависимости:** BE-01, BE-05, BE-07, BE-09

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-04, UC-10, UC-12; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanProtocol/AgentEvent.swift`; `Sources/KabanProtocol/DurableDetails.swift`; `Sources/KabanDaemonCore/StoreDetail.swift`; `Sources/KabanDaemonCore/StoreSubscription.swift`.

### Описание

- Реализовать log read/tail offsets, batches и transport delivery; stdout/stderr
  хранить локально с редактированием секретов и установленной retention policy.
- Сохранять runs/artifacts/questions/answers и последнее действие; эфемерный прогресс можно
  коалесцировать, durable task transitions нельзя терять.
- Ограничить страницу/буфер/размер сообщений, дать явный resume/error при backlog;
  TaskDetail не восстанавливается из обрезанного журнала.

### Критерии приёмки

- [ ] log offset не пропускает/дублирует строки после reconnect; удалённый log показывает «недоступен», а не пустой успешный run.
- [ ] Секреты и run-token не попадают в артефакты.
- [ ] Размер snapshot/detail не даёт молчаливой потери: pagination или явная recoverable диагностика.
- [ ] Медленный клиент не останавливает executor.

## BE-17. Реализовать очередь локального слияния

**Приоритет:** P1

**Зависимости:** BE-04, BE-05, BE-06, BE-10, BE-11, BE-12, BE-13

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-07, UC-08; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanKit/Git/DaemonGit.swift`; `Sources/KabanKit/StateMachine/TaskMachine.swift`; `Sources/KabanDaemonCore/StoreScheduler.swift`.

### Описание

- `approve` переводит задачу в очередь merge. Один merge на проект,
  порядок одобрения, fetch из task clone, rebase на свежий main, повтор гейтов.
- Dirty main → blocked:main_dirty и merge_blocked без изменения пользовательских
  файлов. Перед update ref повторить invariant/suspicious-files проверки.
- Конфликт вернуть в первую coding stage, считать conflict limit; после исправления
  всегда снова Human Review. Done только после подтверждённого local fast-forward.

### Критерии приёмки

- [ ] две одобренные задачи не пишут main одновременно.
- [ ] Main изменился между проверкой и update → безопасная повторная сверка, без перетирания.
- [ ] Dirty/index state сохраняется.
- [ ] Crash после merge до receipt сверяется по git фактам, не делает второе слияние.
- [ ] Conflict loop и отмена ожидающего merge проверены.

## BE-18. Реализовать восстановление после сбоя демона

**Приоритет:** P1

**Зависимости:** BE-05, BE-06, BE-08, BE-10, BE-11, BE-17

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-12; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanDaemonCore/KabanStore.swift`; `Sources/KabanDaemonCore/StoreEffects.swift`; `Sources/KabanDaemon/DaemonMain.swift`.

### Описание

- Расширить существующий reducer recovery реальными PID/start checks, убийством
  принадлежащих Kaban process groups, WIP refs и rollback клона.
- Перезапустить gating и reconcile clone/commit/merge/cleanup effects до нового
  admission; восстановить MCP config и leases, отозвать старые run-tokens.
- Добавить crash-point tests до/после spawn, final MCP, commit, merge и receipt.

### Критерии приёмки

- [ ] PID reuse не убивает чужой процесс.
- [ ] После reopen нет второго агента для того же run, lost completion не принимается дважды. daemon_restart не списывает попытку; сохранённый WIP доступен человеку.
- [ ] Human Review/paused/done остаются стабильными, Клиент получает пропущенные события журнала либо замещающий snapshot.

## BE-19. Подключить ручные команды к реальному исполнению

**Приоритет:** P1

**Зависимости:** BE-11, BE-12, BE-13, BE-14, BE-15, BE-16, BE-17, BE-18

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-06, UC-07, UC-10, UC-11, UC-18, UC-25; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanDaemonCore/StoreCommands.swift`; `Sources/KabanDaemonCore/DurableCommand.swift`; `Sources/KabanProtocol/Commands.swift`.

### Описание

- Переиспользовать wire #69, подключить реальные pause/resume/move/cancel/retry,
  model override, answer/approve/reject и восстановление выбранного WIP ref.
- Проверять состояние и разрешённые targets сервером; все applied действия
  correlated и durable, counters меняются по действующему автомату.
- Синхронизировать incident/files/grants lifecycle при действиях человека;
  источник состояния меняется только через подтверждённые переходы автомата.

### Критерии приёмки

- [ ] pauseAll/project не kill, pauseTask kill; move вперёд через проверки отклонён.
- [ ] Answer только agent, stale question/grant/file IDs не применяются.
- [ ] Human Review reject имеет cancel/archive или coding target.
- [ ] Restore не меняет main и не подменяет run receipt.
- [ ] Repeated commandId не повторяет external action.

## BE-20. Упаковать демон и реализовать lifecycle LaunchAgent

**Приоритет:** P1

**Зависимости:** BE-01, BE-07, BE-18

**Требования:** `docs/kaban-mvp-features-usecases.md`, UC-12, UC-20; `docs/architecture-v0.md`.

**Код и материалы:** `Sources/KabanDaemon/DaemonMain.swift`; `Sources/KabanDaemonCore/XPCDaemonListener.swift`; `Sources/KabanTransport/XPCDaemonTransport.swift`; `Kaban.xcodeproj/`; `research/launchd-xpc-packaging.md`.

### Описание

- Положить helper и plist в app bundle, определить stable paths/permissions БД,
  логов и workspace; интегрировать SMAppService lifecycle.
- Signed app ↔ signed daemon XPC same-team; upgrade/restart/unregister сохраняют
  пользовательские проекты/историю. Отдельно developer mode без системной установки.
- Демон работает независимо от открытого окна и не рассчитывает на PATH интерактивной оболочки;
  авторизация и toolchain check из launchd воспроизводимы.

### Критерии приёмки

- [ ] register/requiresApproval/denied/unregister имеют наблюдаемые результаты; после reboot daemon поднимается один раз и восстанавливает очередь.
- [ ] Подписанный клиент с другим Team ID отвергается; тест private endpoint не заменяет эту проверку.
- [ ] Приложение не требует ручного запуска daemon для штатной работы.
