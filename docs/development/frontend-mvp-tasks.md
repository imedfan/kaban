# Frontend-задачи Kaban MVP

Обновлено 7 октября 2026 по поручению Артёма от 6 октября. Полная очередь нативного
frontend: блоки работ, зависимости, результаты и критерии приёмки. Календарных
сроков и разбивки по неделям нет. Номера FE-01–22 прежнего списка сохранены.

**Плановое допущение:** backend завершил весь свой [список BE-01–20](backend-mvp-tasks.md),
включая production Cursor/MCP, гейты, merge, recovery, capabilities, producers и
штатный LaunchAgent. Все результаты ниже требуют реального завершённого бэка;
ошибка, отсутствующее поле или недоступная capability остаются обязательными
состояниями UI. Требования не сокращаются до текущих ограничений реализации.

**База реализации FE-01:** `origin/main` / `5b4fdc5` после `git fetch origin`
6 октября 2026; BE-20 принят в [PR #91](https://github.com/imedfan/kaban/pull/91).
Фактические ограничения (в том числе системная установка helper) остаются
в [current-state](../current-state.md), отдельно от полного объёма очереди.

Исходный образец — переданный `frontend-mvp-tasks.md` от 6 октября с базой
`4e25ca3`. Уже реализованные BoardView/BoardStore/BoardProjection, BoardSet,
формы задач, Markdown и типизированный клиент используются дальше. BE-20 также
содержит DaemonKabanClient/DaemonRuntime и начальный live UI: FE-01–03 доводят
эту интеграцию и её приёмку. Отдельный frontend-автомат и повторная реализация
транспорта не нужны. Checkbox относятся к проверенным критериям приёмки текущей задачи; присутствие
заготовки или проверка прошлого PR их не закрывает. Реализация и незавершённая
системная приёмка отмечаются раздельно. Пробелы дизайна —
[отдельный список](frontend-design-gaps.md).

## Рабочие источники и общие правила

- Поведение: [MVP UC-01–25](../kaban-mvp-features-usecases.md),
  [архитектура](../architecture-v0.md), [решения](../decisions-log.md).
  Маршруты экранов: [frontend plan](../frontend-plan-v0.md) и `docs/frontend/`.
- Дизайн: [закреплённые исходники](../../design/README.md): base для общей
  композиции, v0.2 для моделей/квоты/флагов, v0.2.1 для файлов/возвратов/git/identity.
  Для создания задачи и пустой доски используются существующие токены и native
  controls. Основное приложение — SwiftUI; HTML/CSS/PNG служат источниками.
- App использует BoardStore/KabanClient/BoardProjection и KabanTransport.
  BoardCore зависит только от Protocol; Kit, GRDB и автомат остаются у бэкенда.
  В формах допускаются draft/editing state и отображение готовых правил.
- Карточки, WIP, политика, настройки и счётчики меняются по authoritative
  snapshot/events. `.ok` не переводит карточку и не доказывает завершение effect;
  операции сопоставляются с journal по commandId. Read-only ответы и локальные
  настройки показа применяются непосредственно, без ожидания journal.
- Capabilities проверяются при handshake и смене сервера. Неподдержанное
  действие выключено с объяснением; на mock после ошибки связи не переключаемся.
  Незнакомые тексты/types показываются безопасно; required legacy поля не
  становятся optional ради удобства UI.
- Разрыв связи показывает сохранённую проекцию с отметкой актуальности,
  блокирует новые изменяющие команды и сохраняет drafts/pending envelopes.
  Восстановление решает исход отправки, а не предлагает слепой повтор новым ID.
- `body=nil`, `settings=nil`, `quota=nil`, отсутствующий log/path/policy —
  неизвестность. UI не рисует выдуманные лимиты, модель, цену или успех запуска.
  Agent slots, execution WIP и human admission — разные данные.
- Вся подписка охватывает все проекты; BoardSet хранит только локальный состав
  и порядок дорожек. Скрытие не равно pause/remove. Менюбар и уведомления видят
  и скрытые проекты. Пауза Мака/проекта прекращает новые старты; pauseTask прерывает run.
- У каждой задачи проверяются основной путь, отказ, pending, reconnect и
  настоящее окно: обе темы, минимум размера, длинный текст, empty/error,
  клавиатура. Mock/fixtures проверяют ветви; итоговую интеграцию доказывает live.
- P0 определяет основной путь и устранение блокирующих состояний; P1 — порядок
  завершения остальных требований. P1 входит в полный MVP и не исключается из очереди.
- Все пути в «Код и материалы» ниже относительны корню репозитория; краткие
  имена App-файлов относятся к `App/KabanApp/`. DTO сверяются с реальным Protocol,
  а предложенное имя нового store не требует отдельного target.

## Блоки и результаты

| Блок | Задачи | Пользовательский результат | Доказательство результата |
| --- | --- | --- | --- |
| 1. Runtime и самостоятельный старт | FE-01–03 | App подключается к helper и восстанавливает сессию; готовность Cursor понятна | Чистая установка, handshake, restart/reconnect, сохранённые pending/drafts |
| 2. Проекты и живая доска | FE-04–07 | Репозиторий и задачи управляются из нативного окна | Add/relink/remove, create/edit, drag/pause/cancel, durable reopening |
| 3. Запуски, решения и завершение | FE-08–12 | Человек наблюдает run, отвечает, делает review и получает локальный merge | Cursor/MCP → gates → review → merge → Done; WIP и conflict paths |
| 4. Полная конфигурация | FE-13–17 | Pipeline, модель, git, workspace и MCP настраиваются в App | Validated apply, resolved policy, сохранение/перезапуск, grants lifecycle |
| 5. Исключения и управление ресурсами | FE-18–20 | Ожидание не становится тупиком: файлы, incident, лимиты и квота имеют действия | Stale files, resolution, scopes пауз/флагов, consent/nil/stale quota |
| 6. Фоновая работа и приёмка | FE-21–22 | Клиент полезен при закрытом окне и принимается как полный MVP | Менюбар/notification deep links и матрица UC-01–25 с реальным helper |

Это функциональные блоки, а не последовательные календарные этапы.
После FE-01/02 и FE-04 базовый редактор FE-13, каталог FE-14 и MCP FE-16 нужны
для настройки реального pipeline до первого сквозного запуска. Их не откладывают
до завершения всех деталей/review. FE-03 использует FE-04 только в финальном шаге
онбординга; это не цикл реализации. FE-13 и FE-14/16 стыкуются через один draft:
сначала транспорт/validate/apply, затем pickers и формы.

## Блок 1. Runtime и самостоятельный старт

**Результат блока:** Kaban самостоятельно запускает готовый helper, показывает
реальную доску и переживает перезапуск/потерю связи без потери пользовательского ввода.

## FE-01. Подключить реальный daemon client к приложению

**Статус:** принят в main через [PR #92](https://github.com/imedfan/kaban/pull/92),
`db9f73a`. На финальном FE-01 `81c73f3` Linux/native/context jobs обоих CI run
завершились успешно. Штатная XPC-приёмка остаётся зависимостью BE-20.
Проверки и границы: [отчёт FE-01](frontend-fe-01-2026-10-06.md).

**Приоритет:** P0

**Зависимости:** Нет frontend-зависимостей; транспорт и упаковка приходят из завершённых BE-01/20.

**Требования:** UC-12; архитектура §5; `docs/frontend/runtime.md`.

**Код и материалы:** `App/KabanApp/KabanApp.swift`, `BoardStore.swift`;
`Sources/KabanBoardCore/KabanClient.swift`; `Sources/KabanTransport/DaemonClient.swift`;
`Kaban.xcodeproj/project.pbxproj`.

**Контракт бэкенда:** BE-01/20: DaemonClient, CommandEnvelope/CommandReply, sessionUpdates, capabilities, readLog/tailLog.

**Результат:** Основное окно работает с реальной БД демона через единый клиент: команды, события, capabilities и чтение логов доступны всем экранам.

### Описание

- Переиспользовать KabanTransport и DaemonKabanClient/DaemonRuntime из BE-20
  (PR #91) как основу. Довести клиентскую границу для CommandEnvelope/CommandReply,
  session updates, capabilities и log API; все экраны используют одну сессию.
- Сохранять metadata ответа (commandId/seq), точный отправленный envelope и
  его состояние. KabanClient не должен терять информацию, нужную для reconciliation
  после restart/retention. Ответ о принятии команды и завершение внешнего effect
  различаются, особенно для restoreWIP.
- Штатный запуск подключается к установленному демону; mock остаётся явным
  режимом preview/QA. Developer mode использует private stdio и отдельные
  каталоги/БД; режим и источник данных видны пользователю.
- Сохранять один commandId и точный envelope при повторе после потери ответа;
  не отправлять новую команду из-за двойного клика или транспортного retry.
- Управлять временем жизни session и подписок независимо от выбора задачи;
  повторное открытие окна не создаёт второго клиента или daemon writer.

### Критерии приёмки

- [x] Основное окно показывает проекты/задачи выбранной реальной БД, без AppFixture.
- [x] Создание через UI даёт wire-команду и correlated event; потерянный ответ не создаёт дубликат.
- [x] Старый/неподдерживающий backend сообщает protocol/capability error без fallback на mock.
- [x] Developer smoke и штатный XPC разделены явно; закрытие подписки освобождает ресурсы.

**Осталось для полной системной приёмки FE-01:** зарегистрированный helper /
штатный Mach XPC в реальном приложении. Developer smoke это не подтверждает;
отказ установки описан в [BE-20](backend-launch-agent-2026-10-06.md).
FE-02 завершает reconciliation сохранённых отправок после replacement/retention.

## FE-02. Реализовать состояние соединения, catch-up и восстановление проекции

**Статус:** принят в main через [PR #93](https://github.com/imedfan/kaban/pull/93),
`ff04e05`. На финальном коде `f1c0b3b` все шесть context/Linux/native jobs двух
CI runs завершились успешно, включая WindowGroup keyboard smoke. Проверки и
оставшаяся installed XPC/developer live приёмка — [отчёт FE-02](frontend-fe-02-2026-10-06.md).
Эти CI результаты проверены по SHA; это не новый прогон на FE-03.

**Приоритет:** P0

**Зависимости:** FE-01.

**Требования:** UC-12; `docs/frontend/runtime.md`, `docs/frontend/protocol-fixtures.md`.

**Код и материалы:** `BoardStore.swift`; `Sources/KabanBoardCore/BoardProjection.swift`,
`PendingCommands.swift`; `DaemonClient.sessionUpdates`, `SnapshotReplacement`, `DaemonConnectionState`.

**Контракт бэкенда:** BE-01/18: DaemonConnectionState, SnapshotReplacement, journal seq, EphemeralCursor/afterSeq, replay исходной команды.

**Результат:** Разрыв связи и перезапуск демона не теряют задачи, черновики и отправленные решения; пользователь видит актуальность доски и исход каждой операции.

### Описание

- Обработать connecting/synchronizing/connected/reconnecting/disconnected и
  replacement snapshots; journal seq и ephemeral cursor вести раздельно.
- Применять ephemeral updates после journal barrier `afterSeq`; при reset
  заменять и durable state, и текущие volatile значения, очищая устаревшие.
- На reconnect сверять выбранную задачу, видимые проекты, детали и pending
  операции. Не считать отсутствие correlated event в replacement snapshot
  доказательством успеха или отказа; перепроверять исходную команду тем же ID.
- Сохранять открытые пользовательские черновики; resync не отправляет их заново.
  Не сбрасывать TaskCreationPending при replacement без reconciliation исходного
  commandId: задача могла уже сохраниться. Для task/project/global/pipeline/grant
  операций хранить отдельные pending scopes, точный payload и подтверждающий тип события.
- Различать отказ, неизвестный исход отправки, принятую команду с незавершённым
  effect и подтверждённый результат. Успешное receipt без требуемого event не
  завершает внешний effect; новая команда допускается только после разрешения исхода.
- Ограниченный буфер и завершение потока дают наблюдаемое восстановление/ошибку.
  Повторное открытие окна возобновляет одну сессию; lifecycle не принадлежит view
  выбранной карточки. При resync detail selection и detail seq сверяются заново.

### Критерии приёмки

- [x] Event-before-reply, duplicate event, seq gap, restart, retention и overflow проверены.
- [x] Создание/решение review/restore, принятые до потери ответа, разрешаются по исходному commandId без второго действия.
- [x] После reconnect нет потерянных карточек, устаревших флагов и вечного «Отправлено».
- [x] Во время догонки действия заблокированы; после connected доступны без перезапуска App.
- [x] Ответ старого getTaskDetail не подменяет новую выбранную задачу или более свежие детали.

**Осталось для полной native приёмки FE-02:** повторить App + embedded daemon
на финальном HEAD в среде, где создаётся WindowGroup, и keyboard smoke в CI.
Unit/wire tests и screenshots не подменяют эти проверки.

## FE-03. Реализовать онбординг, запуск helper и проверку окружения

**Статус:** UI и typed environment store реализованы в отдельной
`codex/fe-03-onboarding` от main `ff04e05`; [отчёт FE-03](frontend-fe-03-2026-10-07.md).
Полные критерии ниже остаются открытыми: реальные environment wire commands
ещё unsupported, штатная установка helper зависит от BE-20; финальный AddProjectFlow — FE-04.
Расхождения бэка записаны [отдельно](frontend-backend-integration-gaps.md),
недостающие кадры — в [списке дизайнера](frontend-design-gaps.md).

**Приоритет:** P0

**Зависимости:** FE-01, FE-02; финальный шаг онбординга использует готовый AddProjectFlow FE-04.

**Требования:** UC-01, UC-12, UC-20; `docs/frontend/projects-and-onboarding.md`.

**Код и материалы:** `KabanApp.swift`, app lifecycle/Settings;
`XPCDaemonTransport.swift`; `CursorEnvironment`, `EnvironmentReport`; `research/launchd-xpc-packaging.md`.

**Контракт бэкенда:** BE-07/20: SMAppService, checkEnvironment/getCursorEnvironment/configureCursor, recheck(.runner), сохранённые настройки чистой БД.

**Результат:** Пользователь устанавливает и запускает Kaban, разрешает helper, проверяет Cursor и доходит до добавления проекта без ручного запуска демона.

### Описание

- Завершить пользовательский flow поверх SMAppService lifecycle BE-20: регистрация,
  requiresApproval/denied, открытие Login Items и повторная проверка при возврате.
  Клиентская UI-часть здесь; использовать готовую упаковку, подпись и daemon paths BE-20.
- Согласовать доступ App и демона к repo/YAML/clone/logs в принятой конфигурации
  безопасности. Выбор папки даёт клиенту разрешение, но не доказывает права helper;
  bookmarks нужны только там, где требует итоговая конфигурация приложения.
  Отказ доступа и утраченное разрешение после restart имеют явный путь исправления.
- Выполнить XPC handshake, `checkEnvironment/getCursorEnvironment`, выбор пути
  executable через `configureCursor` и `recheck(.runner)`.
- Показать отдельные причины: CLI отсутствует, не запускается, не авторизован,
  git/toolchain/sandbox недоступны. Логин выполняется поддерживаемым способом
  Cursor; UI даёт инструкцию и «Проверить снова», секретов не собирает.
- Разрешить пропуск необязательных уведомлений; привести к добавлению первого
  проекта FE-04. Недоступный runner не запрещает хранить задачи в Backlog.

### Критерии приёмки

- [ ] На чистой установке пользователь доходит до первой задачи без ручного daemon/SQL.
- [ ] requiresApproval/denied не выглядят успешным соединением; проверен возврат из Settings.
- [ ] Выбранный CLI path переживает перезапуск; повторная проверка отражает факты демона.
- [ ] Закрытие/повторное открытие окна не регистрирует второй helper; developer mode работает отдельно.

## Блок 2. Проекты и живая доска

**Результат блока:** пользователь подключает репозиторий, ведёт задачи и управляет
ими на доске; состояние сохраняется демоном, набор дорожек — приложением.

## FE-04. Реализовать добавление, удаление и переподключение проектов

**Приоритет:** P0

**Зависимости:** FE-01, FE-02; flow выбора папки и её разрешений реализуется здесь и переиспользуется онбордингом FE-03.

**Требования:** UC-01, UC-14; `docs/frontend/projects-and-onboarding.md`.

**Код и материалы:** `BoardView.swift`, `BoardStore.swift`;
`Sources/KabanBoardCore/IdentityDraft.swift`, `BoardSetStore.swift`; дизайн `06-add-project-identity`.

**Контракт бэкенда:** BE-02: addProject/removeProject/relinkProject, listBranches/detectGates/recheck(.project), identity_required и project events.

**Результат:** Пользователь подключает свой репозиторий, исправляет автора/путь и управляет проектом из приложения, сохраняя задачи и историю.

### Описание

- Добавить выбор папки и `addProject(path, createTemplate, identity?)`;
  новый проект выводить по projectAdded, с правильным no_pipeline/pipeline_invalid.
- Реализовать identity_required: missing/invalid и найденные значения из params,
  сохранение пути/галочки/ввода и повтор с явным автором. Клиент не читает git config.
- Обработать non-git, повтор проекта, неподдерживаемую базовую ветку, ошибки доступа;
  `listBranches/detectGates` показывают серверные данные без автопереключения ветки.
- Реализовать relinkProject при missing path и removeProject с явным объяснением отмены задач,
  сохранения истории/веток по backend lifecycle и сохранности пользовательского репозитория.

### Критерии приёмки

- [ ] Invalid identity/non-git не добавляют фиктивную дорожку; ошибка сохраняет введённые данные.
- [ ] Новый проект появляется после event и может хранить Backlog при невалидном pipeline.
- [ ] Relink сохраняет projectId/задачи; remove обновляет выбор и доску по authoritative events.
- [ ] Разрешения App/helper на папку проверены после restart; применимые bookmarks восстанавливаются, утраченный доступ исправляется выбором папки.

## FE-05. Завершить живую доску, набор проектов и карточки всех состояний

**Приоритет:** P0

**Зависимости:** FE-01, FE-02, FE-04.

**Требования:** UC-03, UC-05, UC-14–16, UC-23; `docs/frontend/board-and-cards.md`.

**Код и материалы:** `BoardView.swift`, `DesignSystem.swift`;
`BoardSetStore`, `BoardProjection`, `CardPresentation`, `MascotKit`; design base/v0.2/v0.2.1.

**Контракт бэкенда:** BE-04/13/17: PipelineSummary/StageSummary, TaskCard, StageLoad, ProjectSummary, overlapsWith, setMascot.

**Результат:** Доска показывает реальную работу всех выбранных проектов, любые стадии и причины ожидания; состав и порядок дорожек сохраняются локально.

### Описание

- Применить все production stage kinds/display: порядок, скрытие, сворачивание,
  gate strip и доступ к задачам скрытых стадий. Завершить дорожки и компактный вид
  по требованиям; grouping не смешивает разные pipeline как одинаковые стадии.
- Добавить перетаскивание/порядок проектов, пустую доску, show/hide и клавиатурные
  альтернативы; BoardSet хранится локально, подписка охватывает все проекты.
- Показать статусы/reasons, критерии, попытки, возвраты, модель, progress и overlaps
  по Protocol. WIP — только stageLoad; отсутствие загрузки не заменяется подсчётом.
  Слоты агента не включают gating и ожидание человека; числа и ресурсные ограничения
  выводятся из контрактных данных. running не доказывает наличие живого процесса:
  UI различает резервирование и подтверждённое исполнение по фактам бэкенда.
- Использовать существующий mascot kit, пикер `setMascot`, фактуры и доступные
  состояния анимации; progress/countdown только у видимых элементов.

### Критерии приёмки

- [ ] Hide/reorder не отправляют pause/remove и переживают перезапуск.
- [ ] Скрытые проекты сохраняют waiting/incident badges; все стадии и причины имеют понятный текст.
- [ ] WIP shrink показывает реальное превышение без вытеснения карточек; nil load скрывает счётчик.
- [ ] Проверены пустые/длинные дорожки, минимум окна, обе темы и Reduce Motion.

## FE-06. Подключить создание, редактирование, приоритет и поиск задач

**Приоритет:** P0

**Зависимости:** FE-02, FE-04, FE-05.

**Требования:** UC-02, UC-11; `docs/frontend/board-and-cards.md`, `docs/frontend/task-details.md`.

**Код и материалы:** `BoardStore.swift`, task editor sheets в `BoardView.swift`;
`TaskActions`, `TaskMarkdown`, task creation pending.

**Контракт бэкенда:** BE-01/02/19: createTask/editTask/setPriority, taskCreated/taskEdited/taskUpdated, TaskDetail.body.

**Результат:** Пользователь создаёт и редактирует реальные задачи, задаёт приоритет и находит нужную карточку; текст и результаты команд переживают перезапуск.

### Описание

- Подключить существующие формы к createTask/editTask/setPriority,
  проекту и правилам доступности реального backend.
- Сохранить точный Markdown body и нативное отображение; критерии отображать
  по серверному hasAcceptanceCriteria, не вычислять eligibility запуска в views.
- Поддержать Cmd-N, выбор проекта, поиск по title/id, фильтры waiting/incidents
  и понятное отсутствие результатов. Фильтр не меняет состояние задач.
- Сохранить ввод при отказе/разрыве связи; разделить draft, отправленную команду
  и подтверждённое создание. Body неизвестен — редактирование текста недоступно.

### Критерии приёмки

- [ ] Create/edit/priority сохраняются после перезапуска; одна отправка создаёт одну задачу.
- [ ] Новая задача выбирается по correlated taskCreated, включая событие раньше ответа.
- [ ] Running/gating или изменившееся состояние дают отказ без потери черновика.
- [ ] Markdown не нормализуется с потерей содержания; body=nil не отправляется как пустая строка.

## FE-07. Подключить паузу, перенос, отмену и ручной повтор

**Приоритет:** P0

**Зависимости:** FE-02, FE-05, FE-06; специализированный блок файлов FE-18 использует эти действия.

**Требования:** UC-10, UC-11; `docs/frontend/runtime.md`, `docs/frontend/task-details.md`.

**Код и материалы:** task actions/sheets, `BoardStore.send`;
`TaskActions`, `DropRules`, `PendingCommands`; design return sheets.

**Контракт бэкенда:** BE-08/19: pauseTask/resumeTask/moveTask/cancelTask/retryStage, grantAttempts, correlated task events.

**Результат:** Пользователь управляет задачей из карточки, деталей и клавиатуры: пауза, продолжение, перенос, отмена и повтор имеют одинаковые последствия.

### Описание

- Подключить pauseTask/resumeTask/moveTask/cancelTask/retryStage с явным
  taskId/stageId и подтверждением прерывания run для переноса назад.
- Завершить TaskDragItem/drop targets; использовать DropRules для affordance,
  окончательное разрешение остаётся у демона. Между проектами перенос запрещён.
- Диалог отмены везде одинаков: keepBranch выключен по умолчанию,
  подпись об архивной ветке; выключать повторную отправку только затронутой операции.
- Дать ручной повтор и grantAttempts там, где разрешает состояние/kind;
  отдельно показывать влияние действий на текущий suspicious set через FE-18.

### Критерии приёмки

- [ ] Задача не перепрыгивает проверки и не меняет колонку до подтверждённого event.
- [ ] PauseTask останавливает свой run; resume/paused Human Review отображают серверный результат.
- [ ] Cancel с обоими keepBranch вариантами проверен на реальном клоне; late result не возвращает карточку в работу.
- [ ] Пауза Мака/проекта оставляет текущие runs работающими; pauseTask прерывает только run выбранной задачи.
- [ ] У drag есть пункт меню/клавиатурная альтернатива; stale state обрабатывается без зависшего pending.

## Блок 3. Запуски, решения и завершение

**Результат блока:** пользователь видит весь путь задачи, разбирает вопросы и сбои,
принимает review и получает подтверждённое слияние в локальный main.

## FE-08. Завершить детали задачи, ленту и материалы результата

**Приоритет:** P0

**Зависимости:** FE-02, FE-05.

**Требования:** UC-04–06, UC-10, UC-12; `docs/frontend/task-details.md`.

**Код и материалы:** панель деталей в `BoardView.swift`, `BoardStore.refreshDetail`;
`TaskDetail`, `TaskArtifact`, `FeedItem`, `TaskDetailSelection`.

**Контракт бэкенда:** BE-09/11/13/16: getTaskDetail, FeedItem, TaskArtifact, HumanRequest, clonePath, detail/journal events.

**Результат:** В открытой панели задачи видны актуальные описание, вопросы, лента, результаты стадий и материалы проверки без переоткрытия.

### Описание

- Подключить реальный TaskDetail: body, feed, questions/answers, artifacts,
  summaries, gate outputs и clonePath; дать ссылки на соответствующий run/лог.
  Использовать фактический TaskArtifact.kind/text/path: summary, diffstat, commits,
  gate_output, hook, issue и неизвестные типы. Текстовый artifact сохранять доступным
  при невозможности структурированного отображения; цену/usage не выводить из времени.
- Обновлять открытые детали при изменениях, включая question/answer/artifact,
  files/grants/incidents, а не только taskUpdated. Буферизовать события,
  пришедшие во время чтения, и применять после detail.seq.
- Сохранять selection/generation/seq guards, дедупликацию и порядок ленты;
  неизвестный kind показывать как текст с типом, без падения.
- Показать loading, unavailable, empty и retry состояния отдельно;
  данные не восстанавливать только из retained journal.
  detail_too_large и большой artifact имеют явную диагностику и доступные
  отдельные чтения истории/логов; описание задачи не обрезается молча.

### Критерии приёмки

- [ ] Быстрое переключение задач и поздние ответы не показывают чужие детали.
- [ ] Вопрос, прогресс, завершение стадии и gate output появляются в открытой панели без переоткрытия.
- [ ] После retention/restart TaskDetail сохраняет историю и материалы, которые отдаёт backend.
- [ ] Неизвестный artifact/feed kind и отсутствующий clonePath имеют безопасное отображение.
- [ ] Слишком большой ответ отличается от пустых деталей; исходный текст не теряется при ошибке чтения.

## FE-09. Реализовать историю runs, живой лог и восстановление WIP

**Приоритет:** P0

**Зависимости:** FE-01, FE-02, FE-08.

**Требования:** UC-04, UC-10, UC-12; `docs/frontend/task-details.md`.

**Код и материалы:** log/run tabs, новый bounded LogStore;
`getRunHistory`, `DaemonClient.readLog/tailLog`, `AgentEvent`, `RunSummary`, `restoreWIP`.

**Контракт бэкенда:** BE-16/18/19: getRunHistory, RunSummary, readLog/tailLog, LogPage/LogBatch, restoreWIP/wipRestored.

**Результат:** Пользователь понимает ход и исход каждого запуска, читает доступный лог и восстанавливает конкретный WIP из истории задачи.

### Описание

- Показать attempts/current stage entry, requested/actual model, причины конца,
  время, countsTowardLimits и WIP refs из backend history.
- Реализовать read/tail по runId и логическому offset: батчи в read-only native
  text view, поиск, copy, раскрытие tool output, загрузка более ранних строк
  в пределах сохранённого диапазона. Учитывать availableFromOffset/endOffset,
  batch.fromOffset/batch.nextOffset и isComplete
  и log_offset_expired/log_unavailable; старый offset не перенумеровывать.
- Ограничить память; tail существует только у видимой вкладки, autoscroll
  работает только когда пользователь находится внизу.
- Дать restoreWIP с подтверждением для ref/run, полученных от backend, в
  допустимом agent-состоянии. Объяснить восстановление дерева/index клона и
  сохранение текущих правок в WIP; не выполнять git restore клиентом.
- `.ok` при restore означает постановку effect: показывать ожидание до correlated
  wipRestored/taskUpdated либо wip_restore_failed; отмена/перенос могут supersede
  pending restore. После восстановления перечитать details, не менять HEAD/main
  и исходную запись run в интерфейсе.
- Сырой лог открывать по RunSummary.logPath только при доступном файле и разрешении
  клиента; наличие path не является разрешением. Экспорт сохраняет очищенные данные.

### Критерии приёмки

- [ ] Reconnect не пропускает и не дублирует строки; expired offset даёт явную диагностику.
- [ ] Переключение run прекращает предыдущий tail; большой вывод не блокирует окно.
- [ ] Retained/удалённый/недоступный лог различимы; секреты не добавляются UI в экспорт.
- [ ] WIP restore обновляет детали после подтверждения; stale ref отказ не меняет main/карточку локально.

## FE-10. Реализовать ответы на вопросы и замечания агенту

**Приоритет:** P0

**Зависимости:** FE-02, FE-07, FE-08.

**Требования:** UC-06, UC-10; `docs/frontend/task-details.md`.

**Код и материалы:** HumanQuestion/decision block;
`HumanRequest`, `HumanAnswer`, `answerHuman`, `StageSummary.kind`.

**Контракт бэкенда:** BE-09/19: answerHuman(taskId, text, requestId?), HumanRequest/HumanAnswer, durable answer и task events.

**Результат:** Пользователь отвечает на конкретный вопрос или передаёт замечание агенту, видит ответ в истории и продолжение работы.

### Описание

- Показать актуальный вопрос и поле ответа; передавать requestId только
  для конкретного question, замечание — с requestId=nil.
- Поле answerHuman доступно только в agent-стадии и применимом waiting_human;
  на human/gate/merge используются отдельные действия, не этот endpoint.
- Объяснить эффект ответа при retries/run limits по требованиям;
  attempts/runs/приоритет самому не менять.
- Сохранить набранный ответ при отказе/потере связи; устаревший question
  перечитать, не отправлять текст молча другому запросу.

### Критерии приёмки

- [ ] Ответ виден в durable ленте, задача продолжает свою стадию по серверным событиям.
- [ ] Stale requestId не выглядит успешно отвеченным и сохраняет текст пользователя.
- [ ] На human/gate/merge нет активного поля answerHuman; running/gating имеют понятную недоступность.
- [ ] Ответ при suspicious_files не показывает набор принятым; действие объясняет это до отправки.

## FE-11. Реализовать полноценный Human Review

**Приоритет:** P0

**Зависимости:** FE-02, FE-07, FE-08; ссылки на лог/попытки — FE-09.

**Требования:** UC-07; `docs/frontend/task-details.md`.

**Код и материалы:** review/summary tab, decision sheets;
`approve`, `requestChanges`, `reject`, `PipelineSummary.defaultReturnStage`; design `03b-human-review`.

**Контракт бэкенда:** BE-11/13/17/19: approve/requestChanges/reject, summary/diffstat/commits/gate_output artifacts, defaultReturnStage.

**Результат:** Пользователь оценивает результат и принимает решение о ревью: одобрение, возврат с замечанием или отклонение.

### Описание

- Собрать summary стадий, diffstat/commits/gate outputs и факт предыдущего
  конфликта из backend материалов. Для текстовых artifacts использовать
  устойчивый renderer с исходным текстом; неизвестный формат остаётся читаемым.
  Отсутствующие стоимость, usage, SHA или число файлов обозначать как неизвестные.
- Подключить «Одобрить», «Вернуть с комментарием» с явной coding target,
  «Отклонить» в допустимую стадию либо отмену с keepBranch.
- Default target приходит от backend; при nil вернуть нельзя, есть переход
  к ошибкам pipeline. Выбор не предлагает read-only/non-agent/недопустимые стадии.
- «Открыть в Cursor» использует реальный clonePath и проверенный CLI/NSWorkspace
  способ; Cmd-Return доступен только в актуальном review и при отсутствии pending.

### Критерии приёмки

- [ ] Review позволяет оценить реальный результат, открыть клон и отправить замечания без CLI-команд пользователя.
- [ ] Approve ведёт в merge queue; UI не выставляет Done сразу после ответа команды.
- [ ] Возврат/отклонение/keepBranch проверены; invalid_state сохраняет комментарий и обновляет детали.
- [ ] Double click/shortcut и reconnect не отправляют второе решение; return target всегда явная и допустимая.

## FE-12. Показать очередь merge, конфликты и подтверждённое завершение

**Приоритет:** P0

**Зависимости:** FE-02, FE-05, FE-08, FE-11.

**Требования:** UC-08; `docs/frontend/board-and-cards.md`, `docs/frontend/task-details.md`.

**Код и материалы:** merge cards, LaneHeader, summary/feed;
`blocked: main_dirty`, `mergeBlocked`, `StageSummary.onConflict`.

**Контракт бэкенда:** BE-17/18: merge state/events, main_dirty/mergeBlocked, onConflict, commit/ref result, overlapsWith.

**Результат:** Пользователь видит очередь слияния, причину блокировки/конфликт и подтверждённый результат в локальном main.

### Описание

- Различить ожидание merge, rebase/gating, main_dirty, возврат после конфликта,
  conflict_limit и Done по данным демона, без отдельного merge-автомата в App.
- Показать причину блокировки и «Проверить снова» для проекта;
  UI не stash/commit/rebase пользовательский main для снятия флага.
- Показать информацию о конфликте/пересечениях и ссылки к замечаниям,
  повторной coding-стадии и обязательному повторному Human Review.
  overlapsWith — предупреждение о пересечении из backend, не причина блокировки;
  по бейджу доступны связанные задачи, включая скрытый проект.
- Выводить финальные backend commit/ref данные и итог задачи;
  не обещать remote push — сценарий заканчивается локальным merge.

### Критерии приёмки

- [ ] Две одобренные задачи отображают реальную очередь; Done появляется после подтверждённого merge.
- [ ] Dirty main объясняет ожидание, пользовательские файлы не меняются действиями фронта.
- [ ] После конфликта и исправления задача снова проходит Human Review; лимит виден на своей стадии.
- [ ] Перезапуск во время merge даёт итог из recovery без повторного решения UI.

## Блок 4. Полная конфигурация

**Результат блока:** реальный pipeline, модели, workspace, политика и MCP настраиваются
нативно; настройки имеют единый apply и понятную область действия.

## FE-13. Реализовать редактор и безопасное сохранение пайплайна

**Приоритет:** P0

**Зависимости:** FE-02, FE-04; выбор модели — FE-14, MCP — FE-16.

**Требования:** UC-13, UC-19, UC-23; `docs/frontend/pipeline-settings.md`.

**Код и материалы:** project pipeline screen, PipelineEditor state;
`PipelineDraft`, `PipelineContentHash`, `PipelineDraftValidation`, `ValidationIssue`;
`validatePipelineDraft` (основной контракт), `validatePipeline` (legacy validation);
`spikes/frontend/Shared/PipelineYamlEditor.swift` как исследовательский материал.

**Контракт бэкенда:** BE-03: точный YAML, PipelineDraft с baseVersionHash/baseSourceHash/contentHash, validatePipelineDraft/updatePipeline, resolved/issues и pipelineApplied.

**Результат:** Пользователь настраивает pipeline и стадии в приложении; точный валидированный YAML безопасно сохраняется и применяется демоном.

### Описание

- Открывать точный исходный YAML через предусмотренный завершённым контрактом
  доступ к `.kaban/pipeline.yaml`; не восстанавливать YAML из PipelineSummary.
  Различать committed version/source, рабочий файл и локальный draft редактора,
  показывать versionHash/sourceHash и неприменённые изменения.
- Дать список/формы стадий с kind, display, harness/permissions, workspace mode,
  skills, gates/hooks, WIP, timeouts,
  retries, return targets и board limits; модель подключается к FE-14, MCP к FE-16.
  Существующие неизвестные поля/комментарии сохранять; доступен исходный YAML.
- Формировать точный PipelineDraft с baseVersionHash/baseSourceHash/contentHash;
  validatePipelineDraft с debounce, отбрасывание старого ответа по hash/generation.
  Подсветка по path/stageId/severity, fallback на backend message при неизвестном коде.
- Перед apply проверить отсутствие нового изменения файла, атомарно записать
  именно подтверждённый текст по контракту BE-03 и отправить draft в updatePipeline.
  При отказе черновик сохраняется; откат собственной записи допускается только
  если файл всё ещё содержит её байты. Новые внешние правки не перетирать.
- Обработать manual file change, validation недоступна, stale base/hash race,
  recheck/reload и «Применить»; не коммитить git самостоятельно.
- Делить реализацию на проверяемые части: точный YAML + validate/apply; затем
  board/stage forms; затем policy/workspace/model/MCP sections. Каждая использует
  один draft и один apply, не записывает свою урезанную копию pipeline.
  Skill references и неизвестные assets/поля сохраняются; их отсутствие показывает
  серверная валидация. Stage display order не подменяет граф on_success.

### Критерии приёмки

- [ ] Ошибки блокируют сохранение, warnings — нет; required model/Auto/return targets проверяет демон.
- [ ] Чужой проект/base, race и повреждённый YAML не применяются, пользовательский ввод сохраняется.
- [ ] Сохранение формы не теряет комментарии/неизвестные поля; непонятная конструкция доступна в YAML без разрушительного преобразования.
- [ ] Удаление занятой стадии отклоняется; WIP shrink/model/policy changes отражаются после authoritative apply.
- [ ] Запись на диск и отказ backend не перетирают более позднюю внешнюю правку; успешная версия согласована с snapshot.

## FE-14. Подключить каталог моделей, пулы и task override

**Приоритет:** P0

**Зависимости:** FE-02; picker в редакторе — FE-13, task override — FE-07/08.

**Требования:** UC-09, UC-10, UC-22, UC-23; `docs/frontend/pipeline-settings.md`,
`docs/frontend/quota-and-menubar.md`.

**Код и материалы:** ModelPicker, model settings/decision blocks;
`ModelInfo`, `ModelFlag`, `listModels/refreshModelCatalog`, pool-rule commands.

**Контракт бэкенда:** BE-14/15/19: listModels/refreshModelCatalog, model pool rules, setModelOverride, clearModelFlag, ModelInfo/ModelFlag.

**Результат:** Пользователь явно выбирает модели, проверяет пулы и меняет модель конкретной задачи, понимая последствия подмены или недоступности.

### Описание

- Общий picker из реального каталога для agent-стадии и task override:
  explicit ID, семейство, Cm/Om, unavailable и needsReview. Auto и
  автоматического выбора первой модели нет; неизвестный текущий ID не скрывается.
- Подключить refresh, `setModelPoolRule/removeModelPoolRule`, фильтр
  «проверь пул» и подтверждённые изменения rules/catalog. Для таблицы правил
  читать сохранённый список из завершённого backend-контракта, не выводить его
  из текущего списка моделей и не хранить отдельную копию в UserDefaults.
- Дать `setModelOverride` для конкретных task/stage и снятие override;
  отделить его от редактирования модели стадии для всех будущих runs.
  Показать сброс human counter и применение со следующего запуска; текущий
  frozen RunSpec и фактическая модель уже идущего run не переписываются.
- Показать requested/actual/fallback и модельные флаги, retry/смену модели/
  clearModelFlag. Не подтверждённая модель не выдаётся за совпавшую;
  снятие флага не подписывается как гарантированно успешная следующая попытка.

### Критерии приёмки

- [ ] Без выбранной явной модели pipeline не сохраняется; unavailable модель выбрать нельзя.
- [ ] Override влияет только на выбранные task/stage, а правила пула обновляются по данным backend.
- [ ] Подмена и отсутствие actual различимы; «Повторить»/«Другая модель»/«В Backlog» используют реальные команды.
- [ ] Refresh error/reconnect не затирают draft и не подставляют демокаталог.

## FE-15. Завершить настройки проекта, git-политику и workspace

**Приоритет:** P0 для основной конфигурации проекта; P1 для полной поверхности настроек.

**Зависимости:** FE-02, FE-04; YAML-разделы — FE-13, модели — FE-14.

**Требования:** UC-01, UC-14, UC-16, UC-19, UC-25;
`docs/frontend/project-settings.md`, `docs/frontend/pipeline-settings.md`.

**Код и материалы:** project settings screen;
`setProjectIdentity/setProjectWeight/setMascot`, `EffectiveGitPolicy`, `gitCommandCatalog`;
design `03-project-git-presets`, `04-stage-git-overrides`.

**Контракт бэкенда:** BE-02/03/12: setProjectIdentity/setProjectWeight/setMascot, validated pipeline draft, projectGitPolicy/gitCommandCatalog/EffectiveGitPolicy.

**Результат:** Настройки проекта, автора, ресурсов, workspace и git-политики доступны из одного окна с явным местом хранения и областью действия.

### Описание

- Разделить локальные metadata, сохраняемые командой сразу, и `.kaban/`
  настройки с общей draft/apply-механикой FE-13. Показать путь/base branch,
  автора, weight/maxRuns и mascot без записи в UserDefaults вместо backend.
- Реализовать project preset/allow/deny и stage extend/deny/when;
  read-only, committer, hard invariants и эффективная политика — из resolved DTO.
  Свой preset стадии не вводить; действие настроек показывать «с новых runs».
- Добавить workspace warm_paths/on_create и параметры проверки файлов:
  patterns/max_file_mb/allow, не теряя другие YAML-разделы.
- Для неизвестных policy IDs/sources использовать fallback; запрещённые
  инварианты показывать заблокированными. Клиент не резолвит git-policy.

### Критерии приёмки

- [ ] Identity/weight/maxRuns/mascot переживают перезапуск и меняются по projectUpdated.
- [ ] Policy preview совпадает с backend resolved; hard invariants не снимаются из UI.
- [ ] Изменение workspace/files/policy идёт через validated draft и не задевает чужие YAML-поля.
- [ ] Отказ в любом разделе оставляет прежнее authoritative значение и сохраняет draft/ввод.

## FE-16. Реализовать MCP проекта и выбор серверов стадии

**Приоритет:** P0

**Зависимости:** FE-02, FE-04; выбор серверов стадии — FE-13.

**Требования:** UC-24; `docs/frontend/project-settings.md`, `docs/frontend/pipeline-settings.md`.

**Код и материалы:** project MCP settings, StageMcpPicker;
`McpServerRef`, `listProjectMcpServers/setProjectMcpAllowlist`; design `05-project-mcp`.

**Контракт бэкенда:** BE-10: listProjectMcpServers/setProjectMcpAllowlist, McpServerRef, agent.mcp, mcp_not_allowlisted/mcp_unexpected.

**Результат:** Пользователь явно разрешает MCP для проекта и выбирает серверы стадий; UI показывает реально подключаемый набор.

### Описание

- Показать серверы и source project/personal по backend; хранение allowlist —
  у демона на этом Маке. Сервер kaban включён всегда и недоступен для выключения.
- Остальные серверы разрешаются явно; UI не меняет личный `.cursor/mcp.json`
  и не хранит run tokens/credentials.
- В стадии выбирать только разрешённые серверы с сохранением через FE-13;
  выключенный ранее выбранный сервер не удалять молча, показать warning.
- Для mcp_unexpected показать конфликтующий сервер, переход в MCP settings
  и recheck проекта, без предложения «разрешить всё».

### Критерии приёмки

- [ ] Allowlist одного проекта не меняет другие; сохранённый выбор переживает restart.
- [ ] Kaban MCP нельзя отключить; выбранный выключенный сервер даёт warning без блокировки валидного apply.
- [ ] Unexpected server виден и устраняется через явные настройки/повторную проверку.
- [ ] Ошибка чтения списка не показывается как «серверов нет», source collisions различимы.

## FE-17. Реализовать отказы git и жизненный цикл разовых разрешений

**Приоритет:** P0 для разбора блокирующего отказа; P1 для полной истории и редактирования политики.

**Зависимости:** FE-02, FE-08, FE-13, FE-15.

**Требования:** UC-17, UC-19; `docs/frontend/task-details.md`.

**Код и материалы:** GitDenialRow, grants tab, policy preview sheet;
`GitDenialSnapshot`, `GitGrantSnapshot`, grant lifecycle events.

**Контракт бэкенда:** BE-12/16/19: allowGitOnce/revokeGitGrant/addDenialToPolicy, GitDenialSnapshot/GitGrantSnapshot, gitPolicyUpdated и grant events.

**Результат:** Пользователь разбирает отказ git, выдаёт/отзывает разовое разрешение или сохраняет правило в политике, отслеживая его жизненный цикл.

### Описание

- Показать argv/rule/stage/run отказа и цепочку created/delivered/consumed/
  revoked/expired с timestamps из backend. Delivered не равно использовано.
- Подключить allowGitOnce/revokeGitGrant/addDenialToPolicy с явным
  project/stage scope и preview до изменения политики. Для постоянного правила
  подтвердить именно новую committed `.kaban/`-версию и resolved policy:
  один gitPolicyUpdated без новой версии/источника не изображается автокоммитом.
- Для hard invariant кнопок разрешения нет. Статус pending не превращать
  в grant до correlated event; unknown rule/source не переинтерпретировать.
- Обновлять детали и unusedGitGrants badge, объяснять ожидание доставки
  живому/следующему run и доступный retry при git_denials.

### Критерии приёмки

- [ ] Реальный отказ можно разрешить/отозвать; строки/бейджи восстанавливаются после reopen.
- [ ] Повтор allowGitOnce не даёт второго разрешения; stale denial даёт явный отказ.
- [ ] Delivered, consumed и expired различимы; hard invariant нельзя обойти через UI.
- [ ] Добавление в политику показывает принятую версию и действует с новых runs.

## Блок 5. Исключения и управление ресурсами

**Результат блока:** пользователь понимает, почему работа остановилась, и может
разрешить ожидание; инциденты, файлы, лимиты и квота отображаются по данным демона.

## FE-18. Завершить обработку подозрительных файлов

**Приоритет:** P0

**Зависимости:** FE-02, FE-07, FE-08, FE-10; исключения проекта — FE-13/15.

**Требования:** UC-25; `docs/frontend/task-details.md`.

**Код и материалы:** SuspiciousFilesBlock и decision sheets;
`SuspiciousFile`, `FileBlobRef`, `AcceptedFile`; design suspicious/stale/return v0.2.1.

**Контракт бэкенда:** BE-13/19: suspiciousFiles/acceptedFiles, acceptSuspiciousFiles(FileBlobRef), stale_suspicious_files и stage-specific task commands.

**Результат:** Пользователь видит конкретные подозрительные файлы и принимает точное содержимое либо отправляет задачу на исправление с понятным эффектом.

### Описание

- Показать текущий непринятый набор: path, правило, размер, text/blob;
  янтарный waiting со щитом, отдельно от красного incident.
- «Принять файлы» → acceptSuspiciousFiles отправляет ровно показанные path+blob; stale_suspicious_files
  перечитывает набор и требует нового явного действия, без автоматического acceptance.
- Развести stage-specific действия: agent answerHuman просит убрать и не
  принимает; gate/merge requestChanges с замечанием не принимает;
  move/retry/cancel принимают текущий набор по правилам backend.
  Надпись кнопки и предупреждение заранее показывают этот эффект.
- Дать историю acceptedFiles, переход в исключения проекта FE-15 и preview:
  diff только для доступного текстового файла допустимого размера, иначе Finder.
  Путь проверять относительно разрешённого clone root, без следования за его пределы.

### Критерии приёмки

- [ ] Приём актуального набора продолжает отложенный переход без нового run по событиям демона.
- [ ] Изменившийся blob никогда не принимается старым кликом; updated набор виден в панели.
- [ ] Empty/nonempty comment на gate/merge меняет команду и подпись; answerHuman там отсутствует.
- [ ] Принятый набор/история переживают reopen; suspicious не увеличивает incident count.
- [ ] Preview, Finder и отсутствующий клон имеют понятные состояния и соблюдают файловые разрешения.

## FE-19. Реализовать список инцидентов и явные действия по ним

**Приоритет:** P0

**Зависимости:** FE-02, FE-05, FE-07, FE-08; изменение модели — FE-14, политики — FE-15.

**Требования:** UC-18; `docs/frontend/task-details.md`, `docs/frontend/board-and-cards.md`.

**Код и материалы:** IncidentsView, IncidentRow, incident detail block;
`listIncidents`, `ProjectSummary.openIncidentCount`; design `03-task-details`.

**Контракт бэкенда:** BE-13/19: listIncidents(projectIds: nil, state), Incident, ProjectSummary.openIncidentCount, incident/project/task events.

**Результат:** Пользователь находит инциденты всех проектов, понимает нарушение и принимает явное решение; история и счётчики остаются согласованными.

### Описание

- Отдельный раздел по всем проектам, включая скрытые: open/all,
  проект/задача/run/время/тип нарушения, переход к деталям и логу.
- Счётчики использовать из ProjectSummary, не пересчитывать по локально
  загруженной странице списка. Incident events и projectUpdated могут прийти
  в разном порядке без двойного изменения aggregate.
- Показать выполненный backend rollback и ожидание явного решения человека;
  дать только допустимые kind/state действия с их последствиями.
- История остаётся после resolution; policy/grant change не изображается
  как снятие hard invariant или автоматическое продолжение задачи.

### Критерии приёмки

- [ ] Список и глобальный/проектный count согласованы с backend после reconnect/retention.
- [ ] Инцидент скрытого проекта виден; pending resolution не исчезает по одному `.ok`.
- [ ] После действия resolution/карточка/count подтверждены событиями, история доступна.
- [ ] Unknown kind, удалённый проект и отсутствующий лог не ломают просмотр истории.

## FE-20. Реализовать настройки Мака, флаги планировщика и экран квоты

**Приоритет:** P0 для пауз, лимита и blocking flags; P1 для опциональной квоты и расширенных настроек.

**Зависимости:** FE-02, FE-05, FE-14; проверка окружения — FE-03.

**Требования:** UC-09, UC-11, UC-14, UC-20, UC-21;
`docs/frontend/quota-and-menubar.md`, `docs/frontend/board-and-cards.md`.

**Код и материалы:** Mac Settings, Scheduler/Pool/ModelBanner, LaneHeader,
QuotaBars; `GlobalSettings`, `SchedulerFlag`, `ModelFlag`, `QuotaState`, `BillingCycle`.

**Контракт бэкенда:** BE-04/14/15/19: GlobalSettings, SchedulerFlag/ModelFlag/QuotaState, setMaxConcurrentRuns/setQuotaOptions, pauses, resumeAfterRateLimit/recheck.

**Результат:** Пользователь управляет лимитом и паузами Мака/проектов, понимает ограничения Cursor и видит опциональную квоту с источником и свежестью.

### Описание

- Подключить setMaxConcurrentRuns, pauseAll/resumeAll/pauseProject/resumeProject,
  resumeAfterRateLimit/recheck и clearModelFlag; потолок/слоты/веса показывать
  по данным backend. Объяснять: пауза Мака/проекта останавливает новые старты.
- Развести global/project/pool/model flags, cooldown/reset, неизвестную дату,
  no_pipeline/pipeline_invalid/missing и переходы к исправлению.
- Квота выключена по умолчанию, включается с явным согласием и пометкой
  «неофициально»: setQuotaOptions, interval/threshold Cm/Om и backend settings.
  Модели/правила пулов редактируются общим механизмом FE-14.
- Проценты/период/свежесть приходят от producer, UI только отображает;
  nil или старше 30 минут — серая неизвестность. Расчёт календарной доли
  цикла использует Protocol BillingCycle, без фиксированных «30 дней».
- Показывать факт опроса/его ошибки по завершённому producer-контракту.
  Отказ источника квоты — состояние экрана, а не повод подставить значения;
  реактивные ограничения остаются доступными. Токен не нужен в формах,
  UserDefaults, export или командных аргументах клиента.

### Критерии приёмки

- [ ] Ceiling/паузы сохраняются после restart; действующие runs не рисуются остановленными из-за pauseAll.
- [ ] Несколько флагов и пулов не скрывают причины; unavailable Runner имеет «Проверить снова».
- [ ] Нет согласия — опрос не включается; nil Cm/Om не превращается в 0% или 100%.
- [ ] Снятие/истечение флага подтверждается backend, UI не стартует задачи собственным таймером.
- [ ] UC-21 проверен с реальным producer: согласие, обновление, ошибка, отзыв согласия, nil и старые данные; реактивные лимиты проверены отдельно.

## Блок 6. Фоновая работа и полная приёмка

**Результат блока:** Kaban остаётся полезным при закрытом окне, возвращает человека
к нужной задаче и подтверждает полный MVP сценариями и проверкой настоящего окна.

## FE-21. Реализовать менюбар, уведомления и переходы в задачу

**Приоритет:** P1

**Зависимости:** FE-02, FE-03, FE-05, FE-10, FE-11, FE-19, FE-20.

**Требования:** UC-06, UC-07, UC-09, UC-12, UC-18, UC-20, UC-21;
`docs/frontend/quota-and-menubar.md`, `docs/frontend/projects-and-onboarding.md`.

**Код и материалы:** `KabanApp.swift`, app lifecycle;
MenuBarExtra, UserNotifications, локальные notification preferences и event dedup state.

**Контракт бэкенда:** BE-01/09/13/20: единая live-сессия, waiting/incident/flag events, answerHuman, независимый LaunchAgent.

**Результат:** Kaban остаётся доступен в менюбаре, сообщает о требующем внимания состоянии и открывает нужную задачу без поиска по доске.

### Описание

- Менюбар использует ту же live-проекцию: waiting count, flags, известные
  слоты/квота, waiting tasks всех проектов, pause/resume/recheck и открытие доски.
- Закрытие последнего окна оставляет приложение в менюбаре; Quit завершает
  клиентские подписки, но не выдаёт себя за остановку независимого демона.
  Добавить управление автозапуском клиента через SMAppService.mainApp.
- Уведомления waiting_human/review, question с reply action, incident,
  rate limit/runner flags; permission и локальная настройка уведомлений.
  Клик открывает выбранную задачу, даже если её проект скрыт с доски.
- Дедупликация replay/reconnect по событию/состоянию; старый catch-up не
  создаёт шквал уведомлений. Уведомлять только о новом требующем внимания
  состоянии, не о каждом snapshot. Удалённая задача/проект дают понятный результат.
  Ответ из уведомления проходит те же guards,
  commandId и обработку ошибки, что ответ из панели.

### Критерии приёмки

- [ ] Закрытое окно не теряет live updates; менюбар и доска согласованы после повторного открытия.
- [ ] Permission denied не блокирует задачи; выключенная настройка не отправляет уведомления.
- [ ] Одна смена состояния не уведомляет повторно после reconnect/reboot; runner flag не уведомляет по каждой задаче.
- [ ] Notification click/reply открывает актуальную задачу либо сообщает stale/unavailable, не отвечает чужому вопросу.
- [ ] Автозапуск/вход пользователя проверены на штатной сборке вместе с BE-20.

## FE-22. Провести функциональную, визуальную и сквозную приёмку приложения

**Приоритет:** P0 для основного live-сценария; P1 для полной матрицы MVP.

**Зависимости:** Каждый проверяемый инкремент FE-01–21; итоговая приёмка — после всех обязательных результатов.

**Требования:** UC-01–25; `docs/frontend/acceptance.md`, `docs/acceptance-criteria-v0.md`,
`AGENTS.md`, `docs/contributing.md`, `design/README.md`.

**Код и материалы:** существующие BoardCore/Protocol/Transport tests;
`BoardQA.swift`, `Kaban.xcodeproj`, `tools/smoke-daemon-transport.py`;
новые UI/integration проверки добавляются по поведению, без обязательного нового target.

**Контракт бэкенда:** Весь завершённый BE-01–20: production Cursor/MCP, gates/hooks/result check, merge, recovery, real producers и установленный helper.

**Результат:** Полный нативный клиент проходит UC-01–25 с реальным бэкендом, штатным helper и подтверждённым основным путём от установки до Done.

### Описание

- Проверять каждый инкремент, затем выполнить основной live-путь на чистой БД:
  установить/подключить helper → добавить repo → указать explicit model →
  создать задачу → реальный Cursor/MCP → гейты → Human Review → локальный merge → Done.
- Отдельно: question/answer, return с замечанием, reject/keepBranch, pause/cancel,
  retries, conflict/dirty main, WIP restore, files/grants/incidents, runner/model/limit flags,
  disconnect/restart/retention и сохранение истории. Затратные CLI runs проводить
  в рамках порученной runtime-проверки; результаты mocks указывать отдельно.
- Проверить настоящее окно в light/dark, минимальном размере, с длинными
  текстами, пустыми/ошибочными состояниями. VoiceOver, focus, shortcuts,
  Reduce Motion/Transparency и Increase Contrast входят в матрицу.
- Измерить board/log responsiveness и память на рабочих профилях: 5×50 задач,
  расширенный stress 10×500, интенсивный stream и большой лог. Фиксировать
  измеренный результат/устройство; предложенные ранее FPS/latency цели не выдавать за утверждённый gate.
- Зафиксировать SHA, версию CLI/среду, проверенные шаги, screenshots настоящего
  окна и ограничения; обновить current-state/README без заявления непроверенной готовности.

### Критерии приёмки

- [ ] Основной сценарий выполнен с реальным backend/Cursor и установленным helper, без fixture model/quota и SQL seed для первого старта.
- [ ] После обновления bundle служба/клиент используют одну сохранённую БД, проекты и история не теряются.
- [ ] Backend restart/закрытие окна/перезапуск App не теряют задачи, ответы, pending resolution и итог merge.
- [ ] Unit/integration проверки затронутого поведения и App build проходят; UI/signed helper проверены отдельно.
- [ ] UC-01–25 имеют результат и доказательство либо конкретный открытый blocker; optional квота проверяется отдельно.
- [ ] VoiceOver/клавиатура и обе темы проверены; длительный log/event поток не блокирует пользовательские действия.
- [ ] Отчёт различает mock, developer stdio и штатный signed XPC; нет открытого блокера основного сценария.

## Покрытие пользовательских сценариев

| UC | Frontend-задачи |
| --- | --- |
| UC-01 Подключение проекта | FE-03, FE-04, FE-13, FE-14, FE-15 |
| UC-02 Создание задачи | FE-06 |
| UC-03 Автозапуск | FE-05, FE-08, FE-20 |
| UC-04 Прохождение стадии | FE-05, FE-08, FE-09 |
| UC-05 Автоматический возврат | FE-05, FE-08 |
| UC-06 Вопрос и ответ человека | FE-10, FE-21 |
| UC-07 Human Review | FE-11, FE-21 |
| UC-08 Merge и конфликт | FE-12 |
| UC-09 Лимиты Cursor | FE-14, FE-20, FE-21 |
| UC-10 Сбой/повтор/WIP | FE-07, FE-09, FE-10, FE-14 |
| UC-11 Ручное управление | FE-06, FE-07, FE-20 |
| UC-12 Перезапуск и recovery | FE-01–03, FE-09, FE-12, FE-21 |
| UC-13 Редактирование pipeline | FE-13 |
| UC-14 Несколько проектов | FE-04, FE-05, FE-15, FE-20 |
| UC-15 Набор проектов на доске | FE-05 |
| UC-16 Маскот | FE-05, FE-15 |
| UC-17 Отказы и git grants | FE-17 |
| UC-18 Инциденты | FE-19, FE-21 |
| UC-19 Git-политика | FE-13, FE-15, FE-17 |
| UC-20 Cursor недоступен | FE-03, FE-20, FE-21 |
| UC-21 Опциональная квота | FE-14, FE-20, FE-21 |
| UC-22 Подмена модели | FE-14, FE-20 |
| UC-23 Отсутствующая модель | FE-05, FE-13, FE-14 |
| UC-24 MCP проекта | FE-16 |
| UC-25 Подозрительные файлы | FE-18, FE-15 |

FE-02 задаёт правила синхронизации для всех экранов; FE-22 проверяет каждый UC.
UC-21 остаётся опцией для пользователя, но его настройка, работа и отказы входят
в полный frontend backlog. Не включённая пользователем квота не блокирует остальные UC.

## Как сдавать задачи и блоки

- В PR указать FE-номера, полученное поведение, используемые команды/события,
  проверенные отказы и конкретную базу backend. Доведение готовых компонентов
  считается выполнением задачи только вместе с её пользовательским результатом.
- Проверять затронутые BoardCore/Protocol/Transport suites с
  `KABAN_SCENARIOS=Scenarios/M1 swift test --filter <реальный Suite>`;
  для App отдельно `xcodebuild` по инструкции `docs/contributing.md`.
  Добавлять проверки нового поведения и рисков; зеркальные tests не нужны.
- Приложить сценарий в настоящем WindowGroup и кадры изменённых экранов:
  light/dark/minimum, длинные значения и empty/error, клавиатура/VoiceOver.
  Для локального открытия файлов проверить разрешения и отсутствующий файл/клон.
- Для результата блока фиксировать App/backend SHA, transport mode,
  CLI version и шаги live-прогона. Fixture/developer stdio и штатный signed XPC
  обозначаются отдельно. Старый отчёт и green CI не подтверждают новый HEAD.
- Checkbox отмечается только после проверки описанного результата; partial UI
  и открытый сценарий отражаются явно. Обновить current-state и эту очередь
  после принятия инкремента; мерж выполняет Артём.

**Итоговый результат:** один нативный клиент к завершённому BE-01–20, в котором
пользователь проходит UC-01–25, настраивает проект и разрешает все предусмотренные
ожидания без обязательных ручных daemon/SQL/git-команд. Локальный merge завершает
сценарий; remote push в этот MVP не входит.
