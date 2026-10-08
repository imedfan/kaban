# Kaban: текущее состояние

Срез 8 октября 2026. Kaban — основной проект Артёма. Разработка не ограничена
ролью «второй команды»; действующие правила — [contributing](contributing.md)
и [AGENTS.md](../AGENTS.md). Документы и оригиналы дизайна доступны в Git.

## База этого среза

Проверенная после `git fetch origin` база реализации: `origin/main` —
`6aac109` (FE-12, PR #103).
Код BE-01–19 присутствует в main: [PR #89](https://github.com/imedfan/kaban/pull/89)
принёс BE-18 и зависимую цепочку BE-06–17, [PR #90](https://github.com/imedfan/kaban/pull/90)
принёс BE-19. Предыдущий срез `ea02f0c` и статусы stacked-веток устарели.

BE-20 принят в main через [PR #91](https://github.com/imedfan/kaban/pull/91).
Packaging/live adapter присутствуют в checkout; незавершённая системная
приёмка описана в [отчёте BE-20](development/backend-launch-agent-2026-10-06.md).
Наличие кода BE-01–20 не закрывает все критерии backend MVP.

Основной каталог обновлён до main `6aac109`; FE-01 принят в #92, FE-02 —
в [#93](https://github.com/imedfan/kaban/pull/93). Все шесть context/Linux/native
CI jobs финального кода FE-02 `f1c0b3b` успешны, включая native keyboard smoke.
BoardSession, exact replay/pending scopes, drafts, seq/cursor barriers и typed
WIP outcomes после retention теперь присутствуют в main; [отчёт FE-02](development/frontend-fe-02-2026-10-06.md).
FE-03 принят в main через [#94](https://github.com/imedfan/kaban/pull/94): нативный онбординг, environment queries
по capabilities, optional permissions и защита старого journal owner при shutdown.
Проверки и незавершённая live-приёмка — [отчёт FE-03](development/frontend-fe-03-2026-10-07.md).
Основной checkout содержит FE-03; все шесть jobs её финального кода `4307d13` прошли.
FE-04 принята в main через [#95](https://github.com/imedfan/kaban/pull/95): формы
Add/Relink/Remove, durable project drafts, folder bookmarks и серверные reads.
Native private DB сценарий проверил настоящие отказы, Backlog, reopening,
сохранение ID при relink и authoritative remove. [Отчёт FE-04](development/frontend-fe-04-2026-10-07.md).
Первые три критерия FE-04 отмечены; signed App/helper grants после restart
не проверены. Все шесть jobs финального FE-04 `ff584b7` успешны.
FE-05 принята в main через [#96](https://github.com/imedfan/kaban/pull/96):
нативные дорожки/compact, hidden/collapsed/gate, local reorder, truthful WIP,
карточки/reasons/current-run progress и mascot picker. 112 BoardCore tests,
App build, native actions и два запуска App с persisted BoardSet прошли.
[Отчёт FE-05](development/frontend-fe-05-2026-10-07.md) содержит настоящие окна,
непроверенную pointer/system приёмку и отсутствующие process/limit facts.
Все шесть jobs финального FE-05 0dd7172 успешны. Для CI compact cards
вычисляются вне ViewBuilder; композиция и правила группировки сохранены.
FE-06 принята в main через [#97](https://github.com/imedfan/kaban/pull/97): единый exact Markdown
editor/preview, project drafts, stale comparison, typed priority и empty search.
120 BoardCore + 18 wire tests, native Return/lost-reply/restart и 11 layout
кадров прошли. [Отчёт FE-06](development/frontend-fe-06-2026-10-07.md).
Все шесть CI jobs финального FE-06 `af74cde` успешны. Initial priority
в createTask остаётся пробелом UC-02.
FE-07 принята через [#98](https://github.com/imedfan/kaban/pull/98): единые typed task
controls, drag/keyboard alternative, Mac/project pause, correlated flags и
сохранение новых clone commits при отмене. Все шесть CI jobs финального
`b18da15` успешны; основной checkout обновлён до merge `47e64fd`.
[Отчёт FE-07](development/frontend-fe-07-2026-10-07.md) фиксирует 577 tests,
12 minimum кадров и незавершённую pointer/installed приёмку.
FE-08 принята в main через [#99](https://github.com/imedfan/kaban/pull/99):
полный TaskDetail, обновление открытой панели по событиям, лента, вопросы,
stage materials и отдельные history/log reads. Все шесть CI jobs финального
`0c579a9` успешны. [Отчёт FE-08](development/frontend-fe-08-2026-10-07.md)
фиксирует 582 tests, 17 кадров и ограничения системного фокуса/живого Cursor.
FE-09 принята в main через [#100](https://github.com/imedfan/kaban/pull/100): история runs, bounded
read/tail с offset recovery, native TextKit2/find/copy/tool expansion, полный
крупный source и exact WIP confirmation с correlated результатом.
596 tests, App build, native light/dark и 16 000 записей прошли. Настоящий
private daemon проверил retention 76…1100, очищенный экспорт, WIP effect,
backup текущих edits, неизменность main/history, stale ref отказ, reopen
и удалённый log file. [Отчёт FE-09](development/frontend-fe-09-2026-10-07.md)
содержит 18 кадров minimum WindowGroup. Исторические attempt/stage entry
отсутствуют в wire DTO; системные permissions/installed проверки не завершены.
Все шесть CI jobs финального FE-09 `67de3a0` успешны; checkout обновлён до merge `05b60c5b`.
FE-10 принята в main через [#101](https://github.com/imedfan/kaban/pull/101):
нативные ответы на конкретный вопрос и замечания, сохранённый адресованный draft,
inline stale/refusal/pending и ⌘↩. Карточка меняется по correlated event;
замечание не принимает suspicious blobs. 604 tests, App build, native light/dark
и private daemon restart после очистки журнала прошли. [Отчёт FE-10](development/frontend-fe-10-2026-10-07.md)
содержит 26 кадров настоящего WindowGroup и границы проверки. Продолжение
подтверждено до очереди той же agent-стадии; живой Cursor/installed helper
и ручная системная клавиатура остаются в полной приёмке. Все шесть CI jobs
финального кода FE-10 `9849a30` успешны; checkout обновлён до merge `6ae93e0`.
FE-11 принята в main через [#102](https://github.com/imedfan/kaban/pull/102):
материалы ревью, сохранённые комментарии, approve/явный return/reject/keepBranch,
переход к pipeline issues и открытие настоящего клона в Cursor. Все шесть CI jobs
финального FE-11 `e51033d` прошли; merge/main — `11e81d7`.
[Отчёт FE-11](development/frontend-fe-11-2026-10-08.md) сохраняет проверки кода
`7464467` и границы системной приёмки.
FE-12 принята в main через [PR #103](https://github.com/imedfan/kaban/pull/103), merge —
`6aac109`: фактический порядок
merge queue, dirty main/project recheck, durable conflict/gate материалы,
ручной return на лимите и подтверждённый локальный ref/commit. Исправлен priority
в merge scheduler. 620 tests полного прогона и 167 final BoardCore tests прошли;
текущий набор — 621 test. App build, native light/dark и private daemon проверили
два approve/merge, неизменность dirty main, повторный Human Review, recovery
без второго fast-forward и красные gates. [Отчёт FE-12](development/frontend-fe-12-2026-10-08.md)
фиксирует код `5760bea`, настоящие окна и остающиеся producer/system пробелы.
FE-13 подготовлена в `codex/fe-13-pipeline-editor` от `6aac109`: нативные формы
стадий/лимитов и точный YAML, серверная проверка, отдельные черновики проектов,
сравнение внешних изменений и атомарная запись перед authoritative apply.
632 tests полного прогона, 272 tests затронутых клиентских suites, App build
и восемь запусков настоящего WindowGroup с private daemon прошли.
[Отчёт FE-13](development/frontend-fe-13-2026-10-08.md) сохраняет доказательства
и границы. Каталог моделей FE-14, полный settings UI FE-15 и MCP picker FE-16
остаются следующими задачами; полный M1/MVP не принят.
Отчёты development фиксируют проверки своих SHA. Исторические границы отдельных
инкрементов ниже не заменяют актуальную таблицу и ограничения этого среза.

## Что есть в основном коде

| Область | Реализовано | Граница |
|---|---|---|
| Protocol | Типизированные команды, snapshot/details, события, settings, optional Markdown body, legacy decoding | Наличие DTO не означает готовый транспорт |
| Kit | YAML/pipeline validation, git-policy, автомат, retry/return/pause rules, POSIX process group | Spawn и stop сами не являются циклом демона |
| DaemonCore | GRDB store v1–v20, state/journal/outbox и claim/lease/receipt, project/pipeline lifecycle, RunSpec/scheduler, clones/process groups, MCP/gates/hooks/result check, models/limits, grants/incidents/files, logs, merge/recovery/WIP | Код BE-01–19 принят. Обычный loop с явно выбранным runner исполняет task effects; production Cursor/MCP lifetime, часть wire/read/producers и критериев изоляции остаются открыты |
| Daemon/Transport/CLI | Single-writer host, startup recovery, scheduler/observer, XPC/private stdio, snapshot/catch-up/session/ephemeral, capabilities, logs и kabanctl; diagnostic passes | В main есть bundle/LaunchAgent/App integration из #91; штатная установка пока не принята. Наличие scheduler reservation и diagnostic smoke не доказывает живой Cursor |
| BoardCore | KabanClient/MockKabanClient, проекция seq/events, pending commands, BoardSet, DropRules, presentation; BoardSession/reconciliation/drafts, bounded RunLogStore, exact WIPRestoreRequest, HumanAnswerStore и HumanReviewStore; PipelineEditorStore и безопасная запись FE-13 в ветке | Core зависит только от Protocol; FE-01–12 в main; query source и strict apply FE-13 проверены с production store |
| Kaban.app | SwiftUI BoardView/BoardStore, live DaemonKabanClient, create/edit/move/cancel, полные детали/run history, native log/WIP confirmation, ответы/замечания, Human Review, merge, pause/resume, lifecycle UI; редактор pipeline FE-13 в ветке | FE-01–12 в main. В BE-20 normal XPC путь подготовлен; developer private stdio проверен. Установка SMAppService пока отклонена macOS |
| Design | Оригиналы токенов и исходников, 28 уникальных PNG, бренд и mascot kit | Наличие макетов не означает визуальную приёмку приложения |

В normal/developer режиме задачи хранятся у daemon. Только явные fixture QA задачи живут в памяти текущего запуска. Набор видимых проектов сохраняется
в UserDefaults. Pipeline settings подключены в ветке FE-13; остальные настройки,
числовая квота и фактические агентские процессы требуют дальнейшей интеграции.
Полный M1/MVP не принят; ограничения fake engine описаны в
[headless contract](development/m1-headless-contract.md).

## UI, принятый в PR #67

PR #67 принят в main; правка `13941e9` интегрирует типизированный клиент.
Основной WindowGroup использует `BoardView` / `BoardStore` / `KabanClient`.
В BE-20 default подключается к DaemonKabanClient; Protocol fixtures из `AppFixture` остаются для opt-in QA. Строковый автомат `ReferenceDemo` не используется.
Сохранённые `Reference*` views остаются инструментом сравнения и не являются
основным состоянием приложения.

Переработаны сайдбар, заголовок, пропорции колонок, карточки со статусом в нижней
строке, детали поверх доски, поиск/фильтры и формы create/edit/move/cancel.
Кнопки сохраняют текстовые подписи и единые размеры. Пустые проекты изначально
свёрнуты; минимальное окно использует горизонтальную прокрутку доски.
Описание отображается нативно с заголовками, списками и inline Markdown;
редактор сохраняет исходный текст. Cmd-N и Cmd-F направляются к тому же store.

Настройки проекта пока отображают известные значения из snapshot, включая
стадии и preset; неизвестные quota/policy/identity не подменяются демочислами.
Lifecycle проектов и редактор задач приняты в FE-04/06. Редактор pipeline FE-13
использует точный source и общий draft/apply для форм и YAML. Остальные настройки,
принятие файлов и менюбар ещё требуют интеграции; Human Review решения
приняты в FE-11, глобальная/проектная пауза принята в FE-07.
Отдельный строковый demo из прежней версии PR не считается реализацией этих функций.

Сборка и проверенные состояния настоящего WindowGroup фиксируются в
[UI QA](development/frontend-polish-2026-10-05.md). AppKit layout captures не
подтверждают системный compositor, ручные pointer-сценарии и VoiceOver.

## Ближайшие результаты

Порученная backend-очередь — [BE-01–20](development/backend-mvp-tasks.md).
Код BE-01–20 принят; системная приёмка BE-20 остаётся незавершённой.
Полная frontend-очередь — [FE-01–22](development/frontend-mvp-tasks.md): шесть
блоков, контракты, результаты и приёмка UC-01–25. По поручению Артёма она рассчитана
на полностью завершённый BE-01–20, без недель и сроков. Она не сокращает продуктовые
требования до перечисленных ниже текущих пробелов.

1. Принять отдельный FE-13 (pipeline editor), продолжить FE-14–17; завершить
   metadata/system FE-05–09 и зависимости FE-03/04, включая
   штатные live-зависимости; дальнейшие задачи — по одному PR. [Конкретные environment/helper пробелы](development/frontend-backend-integration-gaps.md).
2. Подключить configuration, материалы запуска, review/merge и все способы
   разрешить ожидание по полному frontend-списку.
3. Завершить production Cursor/MCP, недостающие wire/producers и штатную
   регистрацию helper; затем подтвердить сквозной сценарий настоящего приложения.

## Backend: проверенные границы для frontend

Источник поддержки команд — `Sources/KabanDaemonCore/DaemonService.swift` и
реализация соответствующего store. DTO/успешная golden fixture не означают
доступную операцию. В `d3ba1f7`:

- Lifecycle проектов, pipeline validate/apply, task control/Human Review,
  details/runs, logs, model catalog/override, grants/incidents/files, настройки
  лимита/квоты и паузы объявлены supported. Для logs есть readLog и клиентский tailLog.
- `checkEnvironment`, `getCursorEnvironment`, `configureCursor`,
  `listProjectMcpServers`, `setProjectMcpAllowlist` остаются unsupported.
  Runner path сейчас задаётся аргументом `--cursor-agent`, не формой App.
- Обычный loop исполняет ручные process/git effects, gates/hooks/merge/cleanup;
  без явно заданного `--runner` agent start остаётся pending. Production Cursor
  prompt, живой stream/model init и постоянный MCP lifetime к этому loop не подключены.
  `.running` и RunSummary.startedAt сами по себе не доказывают запуск Cursor.
- Числовой quota producer отсутствует; SchedulerInputs хранит факты internal
  producer. Поддержка setQuotaOptions не означает работающий опрос.
  Каталог проверен на тестовой табличной форме; реальный авторизованный CLI,
  изолированный профиль и остановка до первого tool не подтверждены отчётами.
- `addDenialToPolicy` пишет `git_policy_extra` и событие со старой версией;
  новая `.kaban/`-версия и YAML autocommit, требуемые UC-17/19, не реализованы этим
  действием. Frontend не должен показывать такой event как сохранённый YAML.
- `overlapsWith` есть в DTO, но producer пересечений UC-08 в DaemonCore не найден.
  Summary/diffstat/commits/gate outputs передаются текстовыми TaskArtifact;
  структурированный diffstat и цена не должны выдумываться UI.
- В ветке FE-13 `getPipelineSource` читает точный committed/working YAML и hashes
  без journal/receipt; перед update App координирует запись точных байтов.
  Strict draft требует уже записанный working content. Полный model pool read
  и signed App/helper права остаются дальнейшей интеграцией.
- Main daemon на чистой БД не инициализирует GlobalSettings: snapshot.settings
  может быть nil, изменение ceiling требует сохранённых settings. В принятом #91 добавлена
  инициализация для `--launch-agent`/`--initialize`. Обычный запуск без этих
  аргументов по-прежнему допускает nil settings.

Это конкретные расхождения реализации и полного MVP, а не новые требования.

## BE-20 / FE-01: клиентская интеграция

В принятом [#91](https://github.com/imedfan/kaban/pull/91) уже есть embedded helper/plist,
SMAppService lifecycle, DaemonKabanClient/DaemonRuntime, session updates в BoardStore,
блокировка команд до connected, отдельная developer stdio БД и проверка подписанных
peer identities. В отчёте PR — 511 Swift tests, build/packaging и настоящее WindowGroup
с create/edit/pause/resume/cancel и durable reopening. Это проверки его head,
а не новый прогон на текущей ветке.

Системная регистрация helper не прошла: по отчёту PR, sandboxed App пытается
установить unsandboxed helper (`Operation not permitted`, статус notFound).
Register/XPC/restart/unregister/reboot и полный dark/minimum/error UI matrix не приняты.
Настройку безопасности нельзя считать исправленной наличием Mach lookup entitlement.

FE-01 доводит границу KabanClient: точные CommandEnvelope/CommandReply,
capabilities при handshake и reconnect, readLog/tailLog через одну сессию.
ClientCommandJournal сохраняет отправки, receipts и correlated seq в локальном
хранилище клиента, раздельно для installed/developer/fixture источников.
Ответ `.ok` не меняет проекцию. Неопределённая доставка и replacement не снимают
pending создания как доказанный отказ. Mock возвращает те же receipts и честно
отказывает в логах; отсутствие capability блокирует соответствующее действие.

Developer retry сначала закрывает прежний транспорт; обычный запуск не переходит
на fixtures. Источник данных показан в сайдбаре. Панель службы/ошибки использует
общие токены; пробелы исходников — [список дизайнеру](development/frontend-design-gaps.md).
FE-02 принят в main через #93: полный replay/reconciliation сохранённых
отправок после reopen, retention и замены snapshot, восстановление draft и деталей.

## Исторические итоги backend-инкрементов

Далее сохранены границы на момент каждого инкремента. Фразы «следует в BE-N»,
diagnostic pass и результаты tests относятся к его отчёту. Код BE-06–19 уже в main;
актуальный обычный loop и остающиеся пробелы описаны выше.

### Backend: durable wire-команды

Принято в main в PR #69 — [контракт и проверки](development/backend-wire-commands-2026-10-05.md).
`KabanStore.execute` принимает существующий `CommandEnvelope` и возвращает
`CommandReply`. Создание/редактирование/приоритет/перенос/отмена, пауза/возобновление,
retry, answer/approve/requestChanges/reject, details/runs и часть settings/project
metadata используют SQLite. Успех и доменный отказ воспроизводятся после reopen;
повтор исходного запроса не генерирует новые ID/time. Сбой записи receipt откатывает
state/detail/journal/outbox. Неподдержанные команды возвращают `unsupported_command`.

Ручные паузы Мака/проекта сохраняются отдельно от задач и блокируют новый
admission/execution; результаты текущих runs продолжают приниматься. Изменение
флагов фиксируется correlated `settingsChanged.schedulerFlags`; `[]` снимает
флаги, nil сохраняет неизвестность старого DTO. BoardProjection принимает настройки
и флаги из journal, а не из ответа `.ok`. Markdown остаётся единым body;
критерии извлекаются по текущему соглашению task editor.

Приложение продолжает использовать MockKabanClient. На базе #69 регистрация была
внутренним bounded fake API; BE-02 ниже добавляет production lifecycle. Исполнение Cursor,
MCP, quota poller и системная регистрация ещё не реализованы. Это командная граница для
следующего транспортного инкремента, не готовность всего M1/MVP.

### Backend: daemon transport и kabanctl

Принято в main в PR #70 — [контракт и проверки](development/backend-daemon-transport-2026-10-05.md).
`KabanDaemon` открывает выбранную SQLite под эксклюзивной process lease,
выполняет recovery и обслуживает `DaemonService`. `KabanTransport` зависит только
от Protocol; команды повторяют исходный envelope при потере ответа. Снимок
плюс подписка после его seq закрывают промежуток между чтением и подключением.
Подписка читает ограниченные пакеты глобального журнала; live delivery — polling
с паузой 200 мс после catch-up. Перерыв соединения сохраняет курсор;
удалённый журнал/курсор впереди БД требуют replacement snapshot.
Даже полностью очищенный журнал не обнуляет seq. Переполнение клиентского буфера
завершает поток явной ошибкой, чтобы потребитель возобновил catch-up.

XPC Mach adapter на macOS 26 требует подпись того же Team ID с обеих сторон.
Реальный обмен проверяется private anonymous endpoint; это не проверка Developer ID
и регистрации Mach service через launchd. `kabanctl` поддерживает snapshot,
send исходного JSON envelope, subscribe и watch. Для headless smoke есть явный
`--stdio-daemon` с дочерним процессом и временной БД; сетевой endpoint не создаётся.

Основное приложение остаётся на MockKabanClient. На базе #70 host не запускал scheduler loop,
fake driver или внешние effects: транспортный инкремент проверяет сохранение
команд. Production lifecycle проектов добавлен в BE-02 ниже; исполнитель, App integration и системная
регистрация следуют отдельно. Наличие бинарника не означает готовность M1/MVP.

### Backend: BE-01 wire-контракты

Принято в main в PR #71 — [матрица и проверки](development/backend-wire-contracts-2026-10-05.md).
`synchronize` согласует snapshot.seq с независимым cursor эфирного канала;
bounded replay/current, restart/retention, journal barriers и connection states
доступны в opt-in `sessionUpdates()`. Старые snapshot/watch остаются совместимыми.
Capabilities перечисляет все команды и отличает managed fake от production support.

PipelineDraft переносит точный YAML, project/base version и SHA-256. Сервер
проверяет binding и производственный validator, отдаёт resolved validation;
сохранение локального пайплайна добавлено в BE-03 ниже. Типы log pages/tail, Cursor environment и WIP restore
подготовлены; реальное log storage, configuration и restore effect ещё не реализованы.
Эфирный publisher не выдумывает данные отсутствующего Cursor/model/quota producer.
App всё ещё использует mock; новые UI-сценарии и визуальная приёмка не заявляются.

### Backend: BE-02 локальные проекты

Принято в main в PR #72 — [lifecycle и проверки](development/backend-project-lifecycle-2026-10-05.md).
Add/remove/relink, local branches, gate suggestions и recheck(project) работают через
wire; author/canonical path/common Git dir/main проверяются до регистрации.
Шаблон коммитит только `.kaban/` через isolated index и CAS, сохраняя dirty checkout.
Durable intent восстанавливает DB failure после Git commit без повторного коммита.
Missing/invalid pipeline допускает Backlog, но публикует authoritative issues/flags.

Host наблюдает missing folder на startup и background timer; relink сохраняет id,
задачи и историю. Remove отменяет задачи с keepBranch=true, архивирует запись и
сохраняет details/receipts; пользовательский root не удаляется. Физические kill/
archive/cleanup effects ждут executor BE-05/06. На базе #72 production start/scheduler
были заблокированы; BE-04 ниже добавляет admission/start, fake driver не исполняет production effects.
Pipeline apply/reload добавлен в BE-03 ниже. App остаётся на MockKabanClient.

### Backend: BE-03 версии пайплайна

Принято в main в [PR #73](https://github.com/imedfan/kaban/pull/73) — [хранилище и проверки](development/backend-pipeline-storage-2026-10-05.md).
Демон читает immutable blobs из локального `main:.kaban/`, сохраняет полные валидные
версии и referenced skills из того же коммита. Typed draft связывает точный YAML
с проектом и базовой версией; `sourceHash` позволяет безопасно исправлять invalid main.
Apply коммитит только `.kaban/` через isolated index/CAS и durable intent; unrelated
dirty/staged файлы и более поздние правки редактора сохраняются. Существующий YAML
на диске не заменяется: основной UI-контракт записывает draft перед командой,
а отличающаяся рабочая копия остаётся отмечена как неприменённые правки.

Startup, recheck и двухсекундный observer публикуют committed issues, отдельно
проверяют рабочий YAML и автоматически подхватывают ручные коммиты. Невалидный main
блокирует новые привязки/переходы; завершение зафиксированного run принимается,
stage exit откладывается до валидного reload. RunSpec фиксирует pipeline, assets,
identity и git policy; следующий запуск привязывается к новой версии. Удаление
занятой стадии/смена её kind запрещены, WIP shrink не вытесняет задачи.
Production scheduling добавлен в BE-04 ниже; claim/lease/receipt — в BE-05 ниже.
Клоны и процессы следуют в BE-06–08, gates/hooks — BE-11, merge — BE-17;
проверка завершения использует сохранённые invocation fixtures. App не подключён.

### Backend: BE-04 полный планировщик

Принято в main в [PR #74](https://github.com/imedfan/kaban/pull/74) — [планировщик и проверки](development/backend-full-scheduler-2026-10-05.md).
Все допустимые production stage kinds участвуют в выборе: downstream по графу
`on_success`, затем returned/answered, priority и durable FIFO. Weighted cursor
переживает reopen; неподходящий кандидат не удерживает очередь. Один tick допускает
один start/admission и до 32 изменений blocking labels; host pass ограничен восемью ticks.
Пустые timer wakes не накапливают receipts. Команды/observer будят serial coalesced
loop, секундный timer проверяет retry/cooldown без ожидания внутри DB transaction.

Только agent `.running` занимает общий/личный слот. Gate и merge используют
execution WIP; merge сериализован на проект. Human admission хранится до stage exit,
включая pause/reopen; WIP shrink и ручная пауза не вытесняют текущие runs.
Production task-control/Human Review команды доступны через wire. Невалидный main
отклоняет новый admission и human stage exit; завершённый run сохраняет BE-03 deferred exit.

Additive v6 сохраняет факты scheduler/model/pool/quota от internal producers.
Snapshot/live delivery используют сохранённые значения; ручные паузы и intake
вычисляются отдельно. Квота учитывает пул/порог и запас на текущие runs; nil или
данные старше 60 с не выдумывают остаток и оставляют реактивные ограничения.
Каталог обновляется в BE-14, только если задан `--cursor-agent` и текст `--list-models` состоит из строк `id<TAB>name`. Environment и числовая квота по-прежнему не подставляются.
Claim/lease описан в BE-05 ниже. `.running` в инкременте BE-04 — durable reservation
с pending effect, а не доказательство живого Cursor. App остаётся на MockKabanClient.

### Backend: BE-05 исполнение эффектов

Принят в main [PR #76](https://github.com/imedfan/kaban/pull/76) (`ea02f0c`) — [claim, lease и receipt](development/backend-effect-execution-2026-10-06.md).
Additive v7 добавляет fencing, lease, external fact и diagnostic, не переписывая payload.
Один claim коммитится одним UPDATE. Crash до факта можно взять повторно, и это не exactly-once процесса.
Наблюдаемый незаконченный факт не перезапускается и не получает receipt. Finished fact сходится
в один receipt; тот же факт идемпотентен, другой payload конфликтует. Старый lease и superseded
эффект не меняют отменённую задачу. Откат записи не оставляет полуперехода и сохраняет уже записанный факт.
Side effect process/git пишется после commit, вне транзакции SQLite. `deliverFake` отклоняет production.
Старт демона забирает незавершённые leases прежнего процесса. `--effect-pass` по желанию подтверждает
только lifecycle effects и не является поведением по умолчанию. Cursor и process group не исполняются.

### Backend: BE-06 клоны задач

[PR #77](https://github.com/imedfan/kaban/pull/77) принят в составе main через PR #89 — [клоны задач](development/backend-task-clones-2026-10-06.md).
План пути коммитится до `git clone --local`. Повтор после обрыва использует тот же путь и не ставит второй run.
У параллельных задач разные ветки, git dir, config и cwd; `fresh-readonly` получает отдельный клон.
DerivedData и temp лежат внутри клона. Портовый диапазон записывается и не занимает сокет.
`--clone-pass` печатает уже сохранённый результат и не создаёт второй каталог.
Очистка архивирует `refs/kaban/archive/<task>` только при `keepBranch` и удаляет каталог лишь после проверки пути.
Чужой путь и копия пользователя не удаляются. HEAD, `main` и status пользователя не меняются.
WIP save/restore остаётся BE-18/19. Cursor не запускается. Следующий инкремент очереди — BE-07.

### Backend: BE-08 управление процессами

[PR #78](https://github.com/imedfan/kaban/pull/78) принят в составе main через PR #89 — [управление процессами](development/backend-process-control-2026-10-06.md).
`--process-pass` запускает переданный `--runner` через `posix_spawn` в новой process group и пишет pid, pgid и время рождения.
Без флага и без `--runner` демон процесс не порождает и не убивает. Старт `startAgentRun` получает факт `started` и не receipt:
receipt завершил бы стадию. Exit 0 с выводом или грязным клоном даёт `no_final_call` и оставляет ту же стадию.
Тихий exit 0 на этом срезе классифицируется BE-15 как `silent_exit` и `retry_wait` без списания попытки. В самом PR #78 это ещё была метка `silent_deferred` без перехода.
Поздний exit после паузы или `completeStage` не меняет задачу. Crash, stall и wall списывают попытку; паузы — 30 с и 2 мин, третья попытка ждёт человека.
Пауза, перенос и отмена шлют SIGKILL только записанной группе, включая потомков, и не принимают поздний результат.
Повторный stop с чужим pgid не сигналит. Timeout сравнивает часы вызывающего и не блокирует проход.
Crash и timeout пишут `refs/kaban/wip/<run>` внутри клона и откатывают его. `no_final_call` и `gate_failed` клон сохраняют.
Копия пользователя не меняется. Восстановление WIP человеком остаётся BE-18/19. Cursor не запускается.
Обрыв между spawn и записью строки может стартовать процесс дважды; exactly-once внешнего процесса нет.

### Backend: BE-07 драйвер Cursor CLI

[PR #79](https://github.com/imedfan/kaban/pull/79) принят в составе main через PR #89 — [драйвер Cursor CLI](development/backend-cursor-driver-2026-10-06.md).
Парсер NDJSON не обрывает run на неизвестном событии, битой или слишком длинной строке. Модель обязательна: пустое значение, `auto` и placeholder отклоняются до запуска.
`--resume` передаётся только с уже проверенным session id и вместе с `--model`. Без него новая сессия сохраняет переданный контекст и не получает выдуманный id.
Отсутствующий или неисполняемый файл и status «not logged in» ставят `runner_unavailable`. Повтор — через 5 минут и по `recheck(.runner)`.
Без `--cursor-agent` демон Cursor не вызывает. `--approve-mcps` не включён. Платный `-p`, каталог при отсутствии логина, launchd login и MCP preflight не выполнены.
Установленный CLI `2026.09.23-86fc751`: `--list-models` требует аутентификацию, `status` сообщает `Not logged in`.

### Backend: BE-14 каталог моделей

[PR #80](https://github.com/imedfan/kaban/pull/80) принят в составе main через PR #89 — [каталог моделей](development/backend-model-catalog-2026-10-06.md).
`auto` отвергается в YAML и в `setModelOverride`. Override хранится отдельно от версии pipeline и меняет только свою задачу и стадию.
`--list-models` принимается только как строки `id<TAB>name`. Иной непустой текст, включая ошибку аутентификации, не заменяет сохранённые строки.
Новая незапрещённая модель получает `needsReview`. Исчезнувший id блокирует только стадии, которые его используют.
Неизвестное или неоднозначное фактическое имя даёт `model_unconfirmed` и не выдумывает совпадение. Известное другое имя останавливает run как `model_substituted`, не списывает попытку и не считается успехом. Флаги переживают reopen.
Остановка процесса до первого инструмента на этой машине не наблюдалась: CLI не залогинен, платный `-p` не запускался. Process-pass по-прежнему не запускает Cursor.

### Backend: BE-15 лимиты и тихий выход

[PR #81](https://github.com/imedfan/kaban/pull/81) принят в составе main через PR #89 — [лимиты](development/backend-limit-handling-2026-10-06.md).
Известный лимит освобождает только этот run и пишет флаг в той же транзакции. Соседний run доигрывает. Om usage не блокирует cm; unknown usage блокирует Мак. Попытка и `runsSinceHuman` не списываются. Cooldown 15/30/60 переживает reopen; `resumeAfterRateLimit` снимает только rate limit. `quota=nil` не считается 100% свободно.
Тихий exit ждёт пробу: одна запись на модель, не чаще 10 минут, без `cursor-agent -p` и без обычного рестарта. Неизвестный текст остаётся одной редактированной строкой ленты. Платный `-p` не запускался.

### Backend: BE-09 MCP-сервер доски

[PR #82](https://github.com/imedfan/kaban/pull/82) принят в составе main через PR #89 — [MCP-сервер](development/backend-mcp-server-2026-10-06.md).
Пять инструментов слушают только `127.0.0.1`. Токен run передаётся в `KABAN_RUN_TOKEN` и в базе хранится как SHA-256. Чужой, отозванный и токен прошлого run не меняют задачу. Подмена `taskId` отклоняется. Повтор `complete_stage` не создаёт второй переход: задача входит в `gating` и получает `.runGates`, не следующую стадию и не Done. Нелегальный `return_to_stage` отклоняется. `request_human` освобождает слот. Notices уходят только адресату.
`listProjectMcpServers` и `setProjectMcpAllowlist` остаются неподдержанными. Обычный запуск демона сервер не держит. `/git/check` добавлен в BE-12 на том же loopback-сервере.

### Backend: BE-10 изоляция MCP

[PR #83](https://github.com/imedfan/kaban/pull/83) принят в составе main через PR #89 — [изоляция MCP](development/backend-mcp-isolation-2026-10-06.md).
Чужой или нечитаемый `mcp list` блокирует старт и не включает `--approve-mcps`. Сервер вне allowlist даёт предупреждение и не попадает в конфиг. Токен в файле только как `${env:KABAN_RUN_TOKEN}`. Подмена `.cursor/mcp.json` снимается до пустого diff.
Профиль запрещает прямую запись и `/usr/bin/git config` в `.git` клона. Это не гарантия изоляции: CLI остаётся вне профиля, чтение широкое, токен CLI не спрятан. Установленный CLI не залогинен, поэтому auth, сборка и MCP в реальном профиле не подтверждены.

### Backend: BE-11 гейты и передача стадии

[PR #84](https://github.com/imedfan/kaban/pull/84) принят в составе main через PR #89 — [гейты стадий](development/backend-stage-gates-2026-10-06.md).
`complete_stage` входит в `gating`. `--stage-pass` исполняет hooks, гейты, проверку результата и один commit и не запускает Cursor. Зелёный exit без final call стадию не закрывает. Красный гейт агента остаётся на том же клоне; красная gate-стадия возвращает в coding-стадию и не повторяется на месте. Возврат несёт конкретные issues, новый заход обнуляет attempts. Replay не пишет второй commit и не запускает hook снова. Пайплайн доходит до Human Review.
Проверка результата в этом инкременте читает только грязь read-only. Грязное дерево обычной стадии для этой проверки считается чистым. Подозрительные файлы и инциденты — BE-13. Merge остаётся BE-17. `/git/check` — BE-12.

### Backend: BE-12 git-разрешения

Инкремент [PR #85](https://github.com/imedfan/kaban/pull/85) принят в составе main через PR #89 — [git-разрешения](development/backend-git-grants-2026-10-06.md).
`/git/check` и shim разрешают git только после ответа демона. Разрешение одноразовое и совпадает с argv целиком. Условный override проверяет сервер. Доставка notice grant не тратит. Пятый отказ run останавливает задачу без списания попытки. `done` и `cancel` истекают grant и оставляют argv. Cursor rules содержат только жёсткие команды.
Дополнительный запрет виден следующим run. Автокоммит YAML не делается, production `updatePipeline` не поддержан. Прямой `/usr/bin/git` shim обходит. Подозрительные файлы — BE-13, merge — BE-17.

### Backend: BE-13 подозрительные файлы и инциденты

Инкремент [PR #86](https://github.com/imedfan/kaban/pull/86) принят в составе main через PR #89 — [инциденты](development/backend-incidents-2026-10-06.md).
После run демон сравнивает refs, tags и `config` основного репозитория со снимком prepare, затем `.kaban/` и предка task branch. Нарушение откатывает git, открывает durable incident и ставит `waiting_human: incident`. Попытка не списывается, следующий tick run не начинает. `incidentOpened`/`incidentResolved` и `projectUpdated` несут один `commandId`. Снимок суммирует `ProjectSummary.openIncidentCount`. Клиент не увеличивает счётчик по предметным событиям. `projectRemoved` пересчитывает сумму.
Подозрительные файлы ищутся после зелёных гейтов. Стандарт смотрит зафиксированный diff, strict — ещё и незакоммиченное. `.cursor/mcp.json` возвращается к `main` и в набор не входит. `answerHuman` и `requestChanges` набор не принимают. `retryStage`, `moveTask`, `cancelTask` и `reject` в стадию принимают его по UC-25. Чужой набор даёт `stale_suspicious_files`. Новый blob того же пути срабатывает снова. Принятие текущего набора продолжает отложенный переход без нового run.
Обычная грязь без read-only остаётся чистой. Откат git выполняется до записи инцидента: сбой записи не обещает exactly-once внешнего git. Merge и production `updatePipeline` не входят в инкремент.

### Backend: BE-16 логи запусков

Инкремент [PR #87](https://github.com/imedfan/kaban/pull/87) принят в составе main через PR #89 — [логи запусков](development/backend-run-logs-2026-10-06.md).
`readLog` отдаёт нормализованные события по смещению. Повтор смещения не дублирует и не пропускает строки. Нет файла или строки — `log_unavailable`, не пустая успешная страница. Префикс старше 1024 событий не перенумеровывается: чтение до него — `log_offset_expired`. `--log-pass` печатает ту же страницу и не запускает Cursor.
Секреты и `KABAN_RUN_TOKEN` вырезаются до записи лога, артефакта, вопроса, ответа и резюме. Снимок и detail больше 8 МиБ возвращают `snapshot_too_large` и `detail_too_large`; сохранённый текст не укорачивается. `getRunHistory` остаётся отдельным ответом. Медленное чтение лог не удаляет, и планировщик продолжает следующий tick.
Файл `Logs/<run-id>.jsonl` не откатывается вместе с SQLite. Пропавший файл — `log_unavailable`, даже если строки остались. Это не exactly-once файла. Очередь локального слияния — BE-17.

### Backend: BE-17 очередь локального слияния

[PR #88](https://github.com/imedfan/kaban/pull/88) принят в составе main через PR #89 — [очередь слияния](development/backend-merge-queue-2026-10-06.md).
Один merge на проект, в порядке одобрения. `--merge-pass` забирает ветку task clone, перебазирует её на свежий `main` во временном клоне, повторяет гейты и fast-forward'ит ref только когда `main` совпал с tip. Cursor этот проход не запускает. Обычный запуск демона `main` не двигает.
Dirty checkout с пересечением путей даёт `blocked: main_dirty` и `merge_blocked` без смены байтов, index и worktree. Сдвиг `main` между rebase и update возвращает фазу в rebase и не затирает чужой commit. Crash после fast-forward и до receipt сверяется с git и не делает второй `update-ref`. Это не exactly-once внешнего git. Конфликт возвращает в coding-стадию и снова требует Human Review; сверх лимита задача ждёт `conflict_limit`. Отмена queued merge не пишет её файл в `main`.

### Backend: BE-18 recovery

Штатный host восстанавливает физические процессы/gates, MCP, WIP и git effects
до запуска scheduler. PID reuse не сигналится; restart не списывает попытку.
[Контракт и проверки](development/backend-daemon-recovery-2026-10-06.md).
BE-18 принят в main через PR #89; runtime ручных действий добавлен BE-19, упаковка — draft BE-20.

### BE-19: ручные действия и WIP

BE-18 — [PR #89](https://github.com/imedfan/kaban/pull/89). BE-19 принят в main
в [PR #90](https://github.com/imedfan/kaban/pull/90), `d3ba1f7`. [Отчёт](development/backend-manual-execution-2026-10-06.md).
Штатный loop исполняет stop/WIP/restore/hooks/gates/merge/cleanup, сериализуя их
с wire-командами. Паузы Мака/проекта сохраняют текущий процесс; pauseTask завершает
принадлежащую группу до cleanup. Override модели сбрасывает human counter и действует
на следующий run, не изменяя frozen RunSpec текущего. Restore принимает только ref
из истории этой задачи, фиксирует SHA, блокирует admission и подтверждает результат
correlated journal event после git/receipt. HEAD/main и исходный run summary сохраняются.
Автоматический production Cursor launch и постоянно работающий MCP-сервер остаются
границами предыдущих инкрементов; локальный runner не подтверждает Cursor auth/isolation.

## Какие источники читать

- [Архитектура](architecture-v0.md) — контракт и границы; [спецификация](kaban-mvp-features-usecases.md) — поведение.
- [Frontend plan](frontend-plan-v0.md) — маршруты к отдельным экранам; [backend plan](backend-plan-v0.md) — исполнитель.
- [Design](../design/README.md) — версии, токены и PNG; [приёмка](acceptance-criteria-v0.md) — MVP.
- [Журнал решений](decisions-log.md) — утверждённые изменения; новые решения должны попасть в соответствующий рабочий документ.
- [Архив](archive/README.md) и [team2](team2/README.md) — происхождение и старые аудиты, читаются по необходимости.

Документация ведётся в Git. [Источники Drive](README.md) сверены и перенесены;
более свежие версии Git сохранены. Drive остаётся внешним историческим источником.
Старые publication manifests относятся к прежним публикациям и не означают
актуальность документов. Для работы внешнее подключение не требуется.

Команды сборки и ограничения среды — [getting started](getting-started.md).
Обновляй этот срез при изменении основного entry point, реализованных функций или границ интеграции.
