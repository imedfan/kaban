# F-T2-5 — фронтенд-план против архитектуры, спеки и протокола

2026-10-04. Проверены frontend-plan v0.5.36, architecture v0.11.22 (§2, §3, §5),
spec v0.8.24 и текущий KabanProtocol после PR #8 (origin/main 1d647ea).
Свежие документы — переданный team2 контекст, не устаревшие docs в repo.
Результат — документ, без production/protocol/плановых правок. Designer задачи,
визуальные макеты, цвета, контраст, Penpot не проверялись.

## Блокеры интерфейсов

### B1. Панель обещает persisted данные, отсутствующие в TaskDetail

План §2, TaskDetailStore: `getTaskDetail → { seq, task, feed, runs, artifacts,
gitGrants, gitDenials, humanRequests, suspiciousFiles, acceptedFiles }`.
§3.6 строит цепочку разрешения после переподключения, §3.7 — сводку/артефакты.
Арх. §5 даёт тот же контракт, §4 хранит историю в долговечных таблицах.

В Sources/KabanProtocol/Commands.swift:198–214 TaskDetail содержит task/feed/runs/
humanRequests/suspiciousFiles/acceptedFiles/clonePath. **artifacts, gitGrants,
gitDenials отсутствуют**; CommandResult.taskDetail передаёт именно этот DTO.
Следствие: клиент не сможет восстановить перечисленные панели из одного detail
после restart/resync/открытия старой задачи, даже если live journal раньше приходил.

Подтверждённый blocker интеграции, дубликат [issue #14](https://github.com/imedfan/kaban/issues/14).
Вопрос Architect: добавить durable DTO/typed detail sections или явно сузить план?
Предложение Frontend: не подменять durable history восстановлением из короткого
журнала событий. Публичные типы team2 не меняет.

### B2. «Этот Мак»/менюбар не имеют snapshot источника настроек

План §2 SchedulerStore: `слоты n/max_concurrent_runs`; §3.9 Settings на все проекты,
§3.12 `слоты n/4`, §3.13 квота enabled/consent/pollInterval/thresholds и pool rules.
Арх. §3.4 / §4 хранит max_concurrent_runs и quota options в settings локальной БД;
§5 getSnapshot перечисляет только board fields, `settingsChanged` — journal event.

Sources/KabanProtocol/Entities.swift:172–208 Snapshot не содержит этих настроек;
Commands.swift имеет setters setMaxConcurrentRuns/setQuotaOptions/setModelPoolRule,
но отсутствует getter настроек; Events.swift:67–71 SettingsChange несёт key/value,
не начальный persisted snapshot. Новому клиенту нельзя надёжно узнать настройку
только по future delta. Модель каталога показывает resolved pool, не исходные rules.

**Blocker восстановления интерфейса, вопрос контракта**, не production defect:
будущего KabanClient ещё нет, поэтому нельзя утверждать, что этот путь уже ломается.
Вопрос Architect: один settings DTO/response/snapshot либо документированный полный
initial settings feed? Не показывать неизменяемое `4` как authoritative ceiling;
не угадывать enabled по quota==nil (nil также означает отсутствие данных).

## Важные вопросы к реализации и данным

### Q1. Текущая модель вида карточки ещё не реализована

План §1: KabanBoardCore включает «вывод визуального состояния карточки»;
§3.4 прямо называет `LimitReasonText { title, qualifier }`; §7 F1 обещает фикстуры
всех строк §3.4. Текущие Sources/KabanBoardCore содержат projection/BoardSet/DropRules/
MascotKit/PendingCommands/IdentityDraft/CommandErrorText, но нет CardViewState,
LimitReasonText, badge ordering или action renderer.

Арх. §2 разрешает такой client presentation слой; **противоречия границе нет**.
Это незавершённая реализация F1, не выдуманный публичный тип протокола и не баг
работающего UI. F-T2-1 проверяет wire/projection inputs, визуальные assertions пока
невозможны. Вопрос Frontend: в какой вехе/API закрываются 22 строки visual table?

### Q2. Лимиты/подозрительные файлы требуют данных, не только статуса

План §3.5: `Всего возвратов N/5`, где denominator = board.bounce_limit_total;
§3.4/3.5 показывают фактический max_file_mb, а не постоянные 5МБ.
Арх. §3.1 конфиг делает их настраиваемыми, спека §1.5/UC-25 также.
PipelineSummary (Pipeline.swift:164–196) несёт maxWaitingHuman/maxRunsPerTask,
но не bounceLimitTotal и suspiciousFiles policy/maxFileMB; TaskCard хранит bounces
и файлы, не эти общие limits. Клиент может иметь raw YAML в editor, но это не
указанный источником слой для обычной карточки/restart/старой задачи.

Вопрос Architect/Frontend: откуда authoritative denominator/threshold получает
обычная board/detail модель? Выбрать DTO или явный display config, не зашивать
пример `5`, не включать validator/resolver из KabanKit. Это **missing-source question**,
не подтверждённый production дефект и не требование добавлять semantic resolver UI.

### Q3. Historical model substitution/usage не равны текущему ModelFlag

План §3.5 ModelSubstitutionBlock: «Запрошена/Ответила (имя и id)», fallbackModel,
run number; вкладка «Попытки» содержит usage; §3.7 «время и стоимость».
RunSummary (Entities.swift:98–123) уже содержит requestedModel, actualModelName,
started/ended, logPath, wipRef, countsTowardLimits — эти поля **есть**, gaps на них нет.
Но actualModelId/fallbackModel/usage/cost в RunSummary отсутствуют. ModelFlag
(Models.swift:43–56) содержит strings requested/actual/fallbackModel, является
current ephemeral состоянием модели; оно может быть снято/заменено и не гарантирует
историю конкретного run. AgentEvent.usage даёт только input/output tokens;
спека не вводит денежный бюджет, арх. §7 usage хранит для будущих метрик.

Вопрос: исторический display собирается из durable run DTO/структурированного feed
или tailLog, а стоимость вообще входит в MVP? Не выводить model id из неоднозначного
имени и не трактовать количество tokens как money. Уровень **важный вопрос**, не bug.

### Q4. «Нет в пресете» требует определения для шаблонов команд

План §3.9: catalog — первые слова, напр. restore; policy.rules может быть
`restore --staged`; клиент «совпадения по префиксу не вычисляет», но список «Нет
в пресете» — catalog entries, которых нет в allowed/denied. Арх. §8.4 и спека
UC-19 также ограничивают client logic отображением, сопоставляет только daemon.
Ровное string set difference может пометить restore отсутствующим при наличии
restore --staged; prefix matching на UI дублирует semantic policy.

Вопрос Architect: contract ready-to-display classification для каждого catalog
entry или правило группировки без утверждения о разрешении всей команды?
Это неоднозначность display contract, **не утверждение о найденном resolver bug**.
Жёсткие инварианты не переводить в настраиваемые команды.

### Q5. Replay гарантии плана шире текущих tests

План §1: then.tasks — ожидаемая карточка после then.events; given.tasks даёт вывод
вида; temporal driver/tick относится демону. Existing ScenarioReplayTests.swift
проверяет full event.data и check на successful steps, then.tasks — только
commandError, и не проверяет большинство backend then.flags/runs/refs outcomes.
Плановый «пока event.data подмножество, накладываем адаптер» устарел: текущие
сценарии имеют полные TaskCard и existing prepare декодирует их напрямую.

F-T2-3 отдельной веткой добавляет независимый 110-field then.tasks oracle для33
сценариев; visual rendering и backend expectations он не реализует. Вопрос Frontend:
обновить plan/test status после приёма F1/F3, не выдавать replay всех файлов за полное
покрытие UC. Severity важно для acceptance evidence, production behavior не меняет.

### Q6. Human WIP формулировку уточнить терминальными статусами

План §3.2/§8: в human WIP занимают «все кроме queued».
TaskStatus.occupiesWIP(in:) (TaskState.swift:16–20) исключает также done/cancelled;
арх. §3.2 terminal WIP не занимает. Как UI direct count это правило использовать
нельзя: план правильно требует stageLoad из демона и скрывает счётчик у старого
демона. Поэтому impact minor, **документная точность**, не проблема actual UI.
Вопрос Frontend: привести пояснение к protocol и сохранить отказ от client fallback.

## Граница логики: что совпало

- §1 / §3.8 validatePipeline + PipelineDraftValidation.resolved: UI не импортирует
  KabanKit/GRDB и не вычисляет effective git policy/return defaults. Package.swift
  у BoardCore зависит только от Protocol; прямого нарушения границы не найдено.
- UI пишет YAML и вызывает updatePipeline(contentHash): это прямо предусмотрено
  арх. §3.1, не перенос validator в клиент. Автор коммитов только daemon identity;
  no optimistic task transitions, commandId correlation, full card replacement — OK.
- §3.2 stageLoad/WIP, §3.7 defaultReturnStage, StageSummary.onFail/onConflict/gates/
  readOnly/gitPolicy, projectGitPolicy/gitCommandCatalog и GitRule.source существуют.
  Остаточные «будут добавлены малым PR» в плане — stale dependency notes после PR8.
- §3.10 identity_required missing/invalid/preserved user input, ProjectSummary.identity,
  unknown legacy nil и first/retry error branch — совпадают со spec0.8.24/Protocol.
- answerHuman только agent, requestChanges/reject return только editable agent;
  suspicious path+blob acceptance и no acceptance by answerHuman/requestChanges — OK.
- Default board-only MCP и explicit allowlist, explicit models/no Auto, no filters
  project scope UI, BoardSet local preferences — принятые решения сохранены.
- Квота optional/read-only UI fallback при системном запросе явно разрешена арх. §7;
  эта узкая оговорка не объявлена нарушением «тонкий клиент».

## UC → экран: полнота планового покрытия

Все **UC-01…UC-25** имеют строку в §4 и соответствующий экран/блок §3; UC без
планового экрана не найдено. Это inventory намерений, не доказательство реализации.

| UC | Плановый экран/раздел | Основной риск данных |
|---|---|---|
| 01,02 | AddProjectFlow3.10 / TaskEditorSheet3.4–3.5 | identity/criteria inputs присутствуют |
| 03,04,05 | Board3.2–3.4 / feed3.5 | renderer future; Q1/Q2/Q5 |
| 06,07 | question3.5 / Review3.7 | durable detail B1, historical Q3 |
| 08 | merge board3.4 / Review3.7 | result/summary B1; daemon state authority |
| 09,10 | banners3.1 / attempts3.5 / quota3.13 | settings B2 / model history Q3 |
| 11,12 | menus3.4 / ConnectionStore2 | real XPC/UI ещё future, state APIs присутствуют |
| 13,14 | pipeline3.8 / project3.9 | DTO config Q2/B2; validator only daemon |
| 15,16 | board set3.10 / mascot | BoardSet/MascotKit APIs существуют, visual не аудитится |
| 17,18,19 | grants3.6 / incidents3.5 / Git3.9 | B1 durable grants; Q4 display contract |
| 20,21,22 | environment3.11 / quota3.13 / substitution3.5 | B2 settings, Q3 history |
| 23,24,25 | editor3.8 / MCP3.9 / suspicious3.5 | resolved fields присутствуют; B1/Q2 detail/config |

## Дедупликация и проверки

#14 — существующий DTO blocker, новой issue не создавали.
#9/#10/#11 — отдельные spec questions основной team2 проверки: лимитные/reset/MCP
не объявляем здесь новыми bugs и не меняем принятые решения.
B2/Q1–Q6 переданы как вопросы Architect/Frontend, им не назначен fictitious issue.

Проверка чтением source declarations/commands/events и plan/spec sections;
`git diff --check` проходит. В этой document-only задаче suite не запускалась:
production/tests не менялись. F1/F2/F3 уже отдельно имеют Mac full-suite evidence;
Linux CI и UI real XPC этим документом не проверены. Уверенность высокая для B1
и field inventories; средняя для display/data contracts с будущим transport UI.
