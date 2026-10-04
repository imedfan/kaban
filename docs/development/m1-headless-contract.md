# M1: контракт управляемого headless-конвейера

2026-10-04. База — `main` после PR #62 (`4303550`). Это контракт следующего
ограниченного инкремента и матрица его приёмки, а не заявление о готовности M1.
API ниже — внутренняя поверхность `KabanDaemonCore`, без XPC. Имена вспомогательных
методов и таблиц может уточнить Backend, сохраняя описанные инварианты.

## Граница инкремента

Управляемый проект использует неизменяемый валидный pipeline
`queue → agent → human → terminal`, явную модель и fake driver с внедрённым
временем. Fake driver выдаёт вопрос, завершение или подтверждение симулированного
effect; настоящих процессов, git, гейтов, Cursor, MCP, сети и квоты нет.
Поддержка других pipelines, их замена во время задачи и реальный executor —
отдельные шаги. Обычный unit-тест чистого автомата не считается fake worker.

Используются существующие `KabanProtocol.Snapshot`, `TaskDetail`, `GlobalSettings`,
`ProjectSummary`, `PipelineSummary`, `HumanRequest`, `HumanAnswer`, `RunSummary`,
`TaskArtifact` и журнальные события. Новый public wire DTO не требуется; `TaskDetail` получает совместимое optional
`body: String?` для Markdown содержимого задачи.
Frontend остаётся на клиентской границе Protocol/BoardCore; Kit/GRDB в приложение
не подключаются. Дизайн и схема транспортного XPC в этом инкременте не меняются.

## Порядок зависимостей

1. Добавить durable project/settings/detail данные и query mapper существующих
   Protocol DTO; расширить команды управляемой задачи.
2. Добавить отдельные durable effects и fake worker: результат и переход
   фиксируются атомарно, повтор доставки безопасен.
3. Добавить scheduler tick поверх тех же команд и worker, проверить admission,
   execution WIP, глобальный потолок и справедливость между проектами.
4. Прогнать сквозную матрицу на временной SQLite БД, затем передать реальные
   DTO/события как fixtures клиентской модели. Подключение XPC следует после
   проверенной portable вертикали.

Architect отвечает за контракт, границы и приёмку; Backend — миграцию,
query mapping, worker, fake driver, scheduler и recovery; Frontend — отображение
этих DTO, pending/error и человеческие команды. Финальное решение о смене статуса
остаётся у демона. `DropRules` — подсказка допустимого жеста, а не серверная
авторизация; новая authoritative move-target поверхность здесь не обещана.

## Внутренняя поверхность

| Операция | Вход и результат | Обязательный эффект |
|---|---|---|
| Регистрация управляемого проекта | `ProjectSummary`, валидный `PipelineConfig`, `commandId`, `at` | Сохранить проект и pipeline; публиковать `projectAdded`/`pipelineApplied`, соблюдать dedup |
| Запись начальных/новых настроек | Явный `GlobalSettings`, `commandId`, `at` | Сохранить и публиковать `SettingsChange.settings` с совместимыми key/value |
| Создание управляемой задачи | `TaskCard`, явный Markdown `body`, `commandId`, `at` | Pipeline загружается из зарегистрированного проекта; task/project связь проверяется |
| `getSnapshot()` | `Snapshot` | Один согласованный read transaction, включая `seq`, настройки, проекты, pipelines, карточки и stageLoad |
| `getTaskDetail(taskId)` | `TaskDetail` | Один read transaction, актуальная карточка и durable детали на том же `seq` |
| Команды задачи | `DurableTaskCommand`, `taskId`, `commandId`, `at` | Сохранить reducer state, projection, feed/detail, journal, receipt и effects одной транзакцией |
| Доставка fake результата | Стабильный effect ID и точный typed результат | Result receipt, вызванные команды/детали/события и ack одной транзакцией |
| Scheduler tick | Replay token `tickId`, явное время | Выбор кандидатов, start receipts/outbox и fairness cursor одной транзакцией |
| Recovery | Существующий replay token `passId`, явное время | Сохранить restart transitions и supersede устаревшие execution effects атомарно |

Существующие `snapshot()` и `createTask(card,pipeline,...)` остаются для unmanaged
v1-задач и совместимости. Новый overload создания управляемой задачи принимает
pipeline только из зарегистрированного проекта. Это не скрытый bootstrap проекта
из task card и не чтение файловой системы по `ProjectSummary.path`.

Командная поверхность дополняется `requestHuman(runId,question)`,
`answer(text,requestId?)`, `approve`, `resultChecked(clean)` и необходимыми
pause/resume событиями. `answer` применима только на agent из `waiting_human`,
не принимает suspicious files, обнуляет `runsSinceHuman`, добавляет попытку только
при исчерпании попыток; bounce counters сохраняются. `approve` применима только
к human review. Если указан requestId, он должен принадлежать данной задаче и
подходящему неотвеченному запросу; чужой ID не закрывает вопрос. Отсутствующий ID
сохраняет существующую семантику замечания агенту.

## Durable schema и истинность данных

Нужна **новая additive migration v2**; уже опубликованный `m1_headless_v1` не
переписывается. Сохраняются его task/event/command/recovery и внутренний API.
Legacy exact outbox импортируется в per-effect представление без повторного
вычисления reducer effects. Автоматическая подмена неизвестных старых полей
продуктовыми defaults запрещена.

Логические записи (JSON payload либо нормализованные таблицы — выбор Backend):

- project и зарегистрированный неизменяемый pipeline snapshot;
- singleton settings с явно сохранённым `GlobalSettings`;
- managed task marker, explicit human admission marker на task/stage entry и metadata FIFO/admission (`queueTime` или созданный seq,
  а не изменяемый `TaskCard.updatedAt`);
- task detail: feed, runs, вопросы/ответы, Markdown body, artifacts и существующие accepted/
  suspicious данные; grant/denial collections сохраняются независимо от journal,
  но создание и исполнение git grants в этом инкременте не поддерживается;
- exact per-effect payload, taskId, version, status и durable result receipt;
- tick receipt и weighted fairness cursor/credits.

Wire queries при неизвестных обязательных legacy project/detail данных
возвращают явную ошибку `incompleteProjection`. Внутренний v1 snapshot продолжает
работать. Явно созданный managed проект с пустой историей имеет настоящие пустые
коллекции; неизвестная история legacy задачи не превращается в «истории нет».

`PipelineConfig.summary(...)` — источник стадии, политик и разрешённых целей;
клиент их не вычисляет. `Snapshot.settings` отражает сохранённые typed значения либо nil при отсутствии;
scheduler не запускает задачи до явного сохранения settings. Сохранённые поля,
включая consent/time, не угадываются; никакой квоты по сети не опрашивается. Scheduler/model flags
и quota не должны выдаваться за проверку реального окружения. `TaskDetail.body = nil` означает неизвестное legacy содержимое: UI отключает
редактирование body до его получения; `""` означает известное пустое содержимое.
`body` опускается при nil и декодируется как optional String, известный неверный
тип отклоняется. Markdown может включать явно составленный раздел критериев
приёмки; отдельного поля `acceptanceCriteria` нет.

`clonePath = nil`
и отсутствие live log честно показывают, что реального clone/process нет.

`ProjectSummary.openIncidentCount` авторитетен, глобальный count равен сумме
проектов. Если incident lifecycle не реализован, инкремент не создаёт fake
инциденты и не заявляет их обработку. При последующем добавлении incident команды
обязаны публиковать `projectUpdated` в той же транзакции.

Feed, run summaries, human requests/answers и artifacts читаются из durable
данных, а не восстанавливаются из journal. История запросов сохраняется после
ответа; answered marker внутренний, wire `HumanRequest` не расширяется. Summary
artifact имеет стабильный ID, task/run/stage связь и время; неизвестный `kind`
сохраняет текст. Existing `humanRequests`, `suspiciousFiles`, `acceptedFiles`
обязательны в TaskDetail JSON. Только новые `artifacts`, `gitGrants`, `gitDenials`
декодируются с `[]` при отсутствии/null и опускаются при пустом encoding.

## Effect identity и fake worker

Effect ID — неизменяемая пара `(commandId, index)`; index соответствует позиции
в уже сохранённом точном массиве non-journal effects. Строковая форма может быть
`lowercase-command-UUID/index`. После миграции тот же batch получает те же IDs.
TaskId и schema version хранятся рядом. Ранее satisfied journal/detail effects
не повторяются как внешняя работа.

Fake driver — детерминированная функция сохранённого effect и явно заданного
сценария. Результаты `question`, `completion`, `ack` различимы; ack означает
симуляцию, а не выполненный git/process. Durable fake result и reducer transition
фиксируются вместе с detail/journal/ack. Повтор ID с тем же результатом возвращает
stored receipt; другой payload того же ID отклоняется. Неизвестный effect ID или
несовместимый result не создаёт переход. Известные fake `commitStage`, `cleanupClone`, `expireGitGrants` получают durable
audit receipt с отметкой simulated, без действий git/process/filesystem. Unknown
unsupported effect остаётся unacked с ошибкой. Internal question/answer/feed/run
проецируются в транзакции команды/result, а не отложенным внешним worker.

Crash до commit не оставляет части результата; crash после commit не повторяет
completion/question/artifact. Это гарантия идемпотентности fake обработки в БД,
**не** exactly-once исполнение реального внешнего процесса. Claim/lease и внешний
side-effect worker потребуют отдельного протокола перед live runner.

После cancel/done/recovery устаревшие launch effects superseded и не доставляются.
Cleanup/kill/rollback effects, действительно требуемые новым состоянием,
сохраняются. Result уже superseded effect не должен вернуть задачу в running.

## Scheduler

Tick ограничен конечным числом admissions/starts и не исполняет бесконечный
конвейер в одной транзакции. Повтор `tickId` возвращает прежний receipt, не выбирает
дополнительные задачи и не двигает fairness cursor. Новая транзакция видит уже
зафиксированные starts — параллельные ticks не превышают лимиты.

- Execution WIP agent/gate/merge: `running + gating + retry_wait`. При запуске
  существующего retry его занятое место не считается второй раз.
- Human admission: explicit persisted marker текущего stage entry, удерживаемый
  до выхода из стадии/final. Queued и paused **до** admission места не занимают;
  waiting_human, paused **после** admission и resumed queued **после** admission
  продолжают занимать одно место. Проверка только status != queued неверна;
  resumed задача не списывает второй slot. StageLoad использует marker.
- Human/queue/terminal admission не расходует глобальный **agent run** slot.
  У managed fixture нет отдельных live gate/merge процессов.
- При уменьшении лимита ниже occupancy существующих задач не вытесняют;
  новые admissions/starts ждут освобождения. Следующая eligible задача не
  блокируется неготовым кандидатом.
- В проекте приоритет: returned/answered раньше новых, затем card priority,
  затем durable FIFO с детерминированным tie-break по task ID. Admission в queue
  требует `hasAcceptanceCriteria`; maxWaitingHuman блокирует новый intake, а не
  начатые задачи. Human review не считается в maxWaitingHuman.
- Между проектами — сохранённый weighted cursor/credits; положительный weight и
  личный maxRuns проверяются. Тест fairness использует постоянно eligible
  проекты и достаточно ticks, не делает вывод из одного выбора.

Точная quantum/credit реализация Backend проверяется тестом отсутствия starvation
и реакции на weight. Минимальная round-robin очередь без учёта weight не объявляется
weighted fairness. Квота, реальные model/scheduler flags, pipeline replacement,
live merge и process reconciliation остаются следующими слоями.

## Матрица приёмки

Каждый сценарий выполняется на disposable SQLite БД с injected clock/fake driver.
Ни один тест не требует HOME, Cursor credentials, сети или системных служб.

| ID | Проверка | Наблюдаемый результат |
|---|---|---|
| HC-01 | Explicit project/settings + managed task | Snapshot содержит сохранённые значения и resolved pipeline; неизвестные settings=nil, scheduler fail closed |
| HC-02 | Unknown legacy projection | Wire query явно incompleteProjection; внутренний v1 snapshot/reopen остаётся совместимым |
| HC-03 | Создание → tick → fake question | Task waiting_human:question, run завершён asked_human, запрос и feed durable, execution slot свободен |
| HC-04 | Ответ → tick → fake completion → human admission | Agent получает answer context; stage summary artifact один; task waiting_human:review |
| HC-05 | Approve → terminal tick | Task done, все известные fake effects drained с truthful audit receipts; устаревшего start нет, detail/history доступны |
| HC-06 | Reopen на running/waiting_human/done | Card, machine counters, pipeline, detail, settings и seq сохраняются; recovery действует только на активные runs |
| HC-07 | Повтор commandId/tickId/effect ID после reopen | Те же receipts; нет второго question/completion/artifact/journal/start и лишнего cursor advance |
| HC-08 | Тот же ID с другим command/effect payload | Явный conflict, состояние и journal не изменены |
| HC-09 | Чужой requestId, answer на human, approve на agent | Reject; вопрос, task и counters не изменены |
| HC-10 | Fail между projection/result и journal/ack | Вся транзакция rollback; retry действительно завершает операцию один раз |
| HC-11 | Stage WIP/global maxRuns и два simultaneous ticks | Starts не превышают лимиты; retry occupancy не удваивается |
| HC-12 | Human admission marker + limit shrink | Queued/paused до admission: 0; waiting/paused/resumed queued после admission: 1 до stage exit/final; повтор admission не удваивает occupancy; новый вход блокируется без вытеснения |
| HC-13 | Приоритет/FIFO и blocked intake | Answered/returned раньше новых, затем priority/FIFO; task без criteria не стартует, но не блокирует eligible |
| HC-14 | Два eligible проекта с разными weights | Нет starvation; результаты конечного набора ticks отражают weight; reopen сохраняет порядок/credits |
| HC-15 | Cancel/recovery между enqueue и fake delivery | Старый launch/result не воскресит задачу; kill/rollback/cleanup нового состояния сохраняются |
| HC-16 | Snapshot → subsequent events в BoardProjection | Итоговые карточки/counts совпадают с новым Snapshot; нет оптимистичных локальных переходов |
| HC-18 | Markdown body wire/durable/readback | nil сохраняет старый JSON shape и запрещает редактирование; known empty/Markdown roundtrip; неверный тип отвергается; reopen сохраняет точный текст |
| HC-17 | Journal retention / независимая история | Удаление старой доставляемой истории не удаляет TaskDetail; query seq не регрессирует; если pruning API пока нет, критерий помечен pending |

Критерии, не покрытые данным PR тестами, отмечаются pending в описании результата,
а не объявляются выполненными по наличию DTO или заглушки. Acceptance не обещает
готовность полного M1: XPC, live effects и ранее перечисленные внешние слои ещё
не входят в этот срез.
