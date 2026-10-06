# Kaban: текущее состояние

Срез 6 октября 2026. Kaban — основной проект Артёма. Разработка не ограничена
ролью «второй команды»; действующие правила — [contributing](contributing.md)
и [AGENTS.md](../AGENTS.md). Документы и оригиналы дизайна доступны в Git.

## База этого среза

Проверенная после git fetch база реализации: `origin/main` —
`ea02f0c` (приняты #63–76, включая native UI #67, transport #70, BE-01–04 #71–74, срез статуса #75 и BE-05 #76).
BE-04 принят в [PR #74](https://github.com/imedfan/kaban/pull/74).
BE-05 принят в main в [PR #76](https://github.com/imedfan/kaban/pull/76) (`ea02f0c`).
BE-06 влит в `codex/be-05-effect-execution` ([PR #77](https://github.com/imedfan/kaban/pull/77)) и ещё не принят в main.
BE-08 влит в `codex/be-06-task-clones` ([PR #78](https://github.com/imedfan/kaban/pull/78)) и ещё не принят в main.
BE-07 влит в `codex/be-08-process-control` ([PR #79](https://github.com/imedfan/kaban/pull/79)) и ещё не принят в main. BE-14 влит в `codex/be-07-cursor-driver` ([PR #80](https://github.com/imedfan/kaban/pull/80)) и ещё не принят в main. BE-15 влит в `codex/be-14-model-catalog` ([PR #81](https://github.com/imedfan/kaban/pull/81)) и ещё не принят в main. BE-09 влит в `codex/be-15-limit-handling` ([PR #82](https://github.com/imedfan/kaban/pull/82)) и ещё не принят в main. BE-10 влит в `codex/be-09-mcp-server` ([PR #83](https://github.com/imedfan/kaban/pull/83)) и ещё не принят в main. BE-11 влит в `codex/be-10-mcp-isolation` ([PR #84](https://github.com/imedfan/kaban/pull/84)) и ещё не принят в main. BE-12 открыт в [PR #85](https://github.com/imedfan/kaban/pull/85) поверх `codex/be-10-mcp-isolation` и ещё не принят в main. BE-13 открыт в [PR #86](https://github.com/imedfan/kaban/pull/86) поверх `codex/be-12-git-grants` и ещё не принят в main.
BE-16 открыт в [PR #87](https://github.com/imedfan/kaban/pull/87) поверх `codex/be-13-incidents` и ещё не принят в main.
BE-17 выполнен в [PR #88](https://github.com/imedfan/kaban/pull/88) поверх `codex/be-16-run-logs` и ещё не принят в main.
Локальная ветка с именем main
может быть старее origin/main; перед новой задачей проверь refs и diff.
Этот документ описывает код принятой базы и инкременты BE-06, BE-08, BE-07, BE-14, BE-15, BE-09, BE-10, BE-11, BE-12, BE-13, BE-16 и BE-17, которые ещё не в main. Отчёты development фиксируют проверки
своих инкрементов, а не новый прогон на текущем HEAD.

## Что есть в основном коде

| Область | Реализовано | Граница |
|---|---|---|
| Protocol | Типизированные команды, snapshot/details, события, settings, optional Markdown body, legacy decoding | Наличие DTO не означает готовый транспорт |
| Kit | YAML/pipeline validation, git-policy, автомат, retry/return/pause rules, POSIX process group | Spawn и stop сами не являются циклом демона |
| DaemonCore | GRDB store, миграции v1–v20, durable state/journal/effects, claim/lease/receipt, клоны задач, process group локального runner, проверка runner, каталог моделей и override, лимитные флаги и проба модели, loopback MCP доски с хешем run-токена, гейты, hooks и один commit стадии, проверка refs/tags/config, `.kaban` и подозрительных файлов, durable incidents, `/git/check` и разовые git-разрешения, чтение логов по смещению событий, очередь одного локального merge с rebase во временном клоне и fast-forward `main`, wire-команды, project lifecycle, pipeline apply/recovery/RunSpec, полный production scheduler и bounded fake driver | Production result не идёт через `deliverFake`. `--cursor-agent` проверяет runner и каталог и не запускает `-p`. Process group исполняется только с `--process-pass`. Проба после тихого выхода не запускает `cursor-agent -p`. MCP и `/git/check` слушают только `127.0.0.1` в `--mcp-pass` и в прямом вызове сервера. Preflight блокирует чужой или нечитаемый `mcp list` и не передаёт `--approve-mcps`. Профиль записи не изолирует токен CLI. Грязное дерево без read-only для проверки результата считается чистым. Откат git при инциденте происходит до записи в базу и не обещает exactly-once. Файл лога не откатывается вместе с SQLite. Fast-forward `main` сверяется с git и не обещает exactly-once. Повторный проход не двигает уже обновлённый ref. Shim не заменяет прямой `/usr/bin/git`. Автокоммит `.kaban/pipeline.yaml` для нового запрета не делается |
| Daemon/Transport/CLI | Host с эксклюзивной lease БД, recovery effect leases, opt-in `--effect-pass`, `--clone-pass`, `--process-pass`, `--mcp-pass`, `--mcp-isolation-pass`, `--stage-pass`, `--log-pass` и `--merge-pass`, XPC listener/client, snapshot/catch-up/live polling, reconnect/resync, kabanctl; capabilities, session/ephemeral, observer и scheduler loop | Transport/BE-01–04 приняты #70–74. `--effect-pass` не запускает Cursor или git. `--clone-pass` не запускает Cursor. `--process-pass` запускает только переданный `--runner` и не запускает Cursor. `--mcp-pass` делает один `complete_stage` через loopback и не запускает Cursor. `--mcp-isolation-pass` только восстанавливает `.cursor/mcp.json`. `--stage-pass` исполняет гейты, hooks, проверку результата и один commit стадии и не запускает Cursor. `--log-pass` только перепечатывает сохранённую страницу лога. `--merge-pass` перебазирует одну одобренную задачу на `main` и fast-forward этого ref и не запускает Cursor. Штатный startup восстанавливает сохранённые gate/merge effects до scheduler. Обычный loop пока не исполняет новые effects и не держит MCP-сервер. Без LaunchAgent packaging, проверки Developer ID и подключения App |
| BoardCore | KabanClient/MockKabanClient, проекция seq/events, pending commands, BoardSet, DropRules, presentation | Отдельный чистый клиентский слой |
| Kaban.app | SwiftUI BoardView/BoardStore, mock-доска, create/edit/move/cancel, детали, pause/resume | Нет связи с DaemonCore через XPC |
| Design | Оригиналы токенов и исходников, 28 уникальных PNG, бренд и mascot kit | Наличие макетов не означает визуальную приёмку приложения |

Mock-задачи живут в памяти текущего запуска. Набор видимых проектов сохраняется
в UserDefaults. Настройки, квота и фактические агентские процессы пока не подключены к приложению.
Полный M1/MVP не принят; ограничения fake engine описаны в
[headless contract](development/m1-headless-contract.md).

## UI, принятый в PR #67

PR #67 принят в main; правка `13941e9` интегрирует типизированный клиент.
Основной WindowGroup теперь использует `BoardView` / `BoardStore` / `KabanClient`
и Protocol fixtures из `AppFixture`, а не строковый автомат `ReferenceDemo`.
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
Редактирование настроек, добавление реального проекта, Human Review решения,
принятие файлов, глобальная/проектная пауза и менюбар ещё требуют интеграции.
Отдельный строковый demo из прежней версии PR не считается реализацией этих функций.

Сборка и проверенные состояния настоящего WindowGroup фиксируются в
[UI QA](development/frontend-polish-2026-10-05.md). AppKit layout captures не
подтверждают системный compositor, ручные pointer-сценарии и VoiceOver.

## Ближайшие результаты

Порученная backend-очередь — [BE-01–20](development/backend-mvp-tasks.md).
BE-01–04 приняты в #71–74.
BE-05 принят в main (#76, `ea02f0c`). BE-06, BE-08, BE-07, BE-14, BE-15, BE-09 и BE-10 влиты в родительские ветки и ещё не в main. Остановка до первого инструмента не проверена. Платный пробный `-p` не запускался. Auth в реальном профиле не проверена. BE-11 влит в `codex/be-10-mcp-isolation` (#84) и ещё не принят в main. BE-12 открыт (#85) поверх `codex/be-10-mcp-isolation` и ещё не принят в main. BE-13 открыт в [PR #86](https://github.com/imedfan/kaban/pull/86) поверх `codex/be-12-git-grants` и ещё не принят в main. BE-16 открыт в [PR #87](https://github.com/imedfan/kaban/pull/87) поверх `codex/be-13-incidents` и ещё не принят в main. BE-17 выполнен в [PR #88](https://github.com/imedfan/kaban/pull/88) поверх `codex/be-16-run-logs` и ещё не принят в main. Следующий в очереди — BE-19. BE-18 реализован в этой ветке; BE-19–20 ещё не завершены.

1. Ручная проверка принятого UI и завершение оставшихся экранов
   настроек/Human Review по закреплённым макетам.
2. Подключение frontend к durable командной границе через готовый транспорт:
   replacement snapshots, pending commands при reconnect и состояние соединения.
3. Реальные Cursor/git/MCP/gates, целевые isolation-спайки и квота.
4. Полная сценарная, визуальная и доступностная приёмка; упаковка/подпись.

Это порядок ориентации, а не запрет выполнять другую явно порученную задачу.
Каждый инкремент должен давать проверяемый пользовательский результат.

## Backend: durable wire-команды

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

## Backend: daemon transport и kabanctl

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

## Backend: BE-01 wire-контракты

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

## Backend: BE-02 локальные проекты

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

## Backend: BE-03 версии пайплайна

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

## Backend: BE-04 полный планировщик

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

## Backend: BE-05 исполнение эффектов

Принят в main [PR #76](https://github.com/imedfan/kaban/pull/76) (`ea02f0c`) — [claim, lease и receipt](development/backend-effect-execution-2026-10-06.md).
Additive v7 добавляет fencing, lease, external fact и diagnostic, не переписывая payload.
Один claim коммитится одним UPDATE. Crash до факта можно взять повторно, и это не exactly-once процесса.
Наблюдаемый незаконченный факт не перезапускается и не получает receipt. Finished fact сходится
в один receipt; тот же факт идемпотентен, другой payload конфликтует. Старый lease и superseded
эффект не меняют отменённую задачу. Откат записи не оставляет полуперехода и сохраняет уже записанный факт.
Side effect process/git пишется после commit, вне транзакции SQLite. `deliverFake` отклоняет production.
Старт демона забирает незавершённые leases прежнего процесса. `--effect-pass` по желанию подтверждает
только lifecycle effects и не является поведением по умолчанию. Cursor и process group не исполняются.

## Backend: BE-06 клоны задач

[PR #77](https://github.com/imedfan/kaban/pull/77) влит в `codex/be-05-effect-execution` и ещё не принят в main — [клоны задач](development/backend-task-clones-2026-10-06.md).
План пути коммитится до `git clone --local`. Повтор после обрыва использует тот же путь и не ставит второй run.
У параллельных задач разные ветки, git dir, config и cwd; `fresh-readonly` получает отдельный клон.
DerivedData и temp лежат внутри клона. Портовый диапазон записывается и не занимает сокет.
`--clone-pass` печатает уже сохранённый результат и не создаёт второй каталог.
Очистка архивирует `refs/kaban/archive/<task>` только при `keepBranch` и удаляет каталог лишь после проверки пути.
Чужой путь и копия пользователя не удаляются. HEAD, `main` и status пользователя не меняются.
WIP save/restore остаётся BE-18/19. Cursor не запускается. Следующий инкремент очереди — BE-07.

## Backend: BE-08 управление процессами

[PR #78](https://github.com/imedfan/kaban/pull/78) влит в `codex/be-06-task-clones` и ещё не принят в main — [управление процессами](development/backend-process-control-2026-10-06.md).
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

## Backend: BE-07 драйвер Cursor CLI

[PR #79](https://github.com/imedfan/kaban/pull/79) влит в `codex/be-08-process-control` и ещё не принят в main — [драйвер Cursor CLI](development/backend-cursor-driver-2026-10-06.md).
Парсер NDJSON не обрывает run на неизвестном событии, битой или слишком длинной строке. Модель обязательна: пустое значение, `auto` и placeholder отклоняются до запуска.
`--resume` передаётся только с уже проверенным session id и вместе с `--model`. Без него новая сессия сохраняет переданный контекст и не получает выдуманный id.
Отсутствующий или неисполняемый файл и status «not logged in» ставят `runner_unavailable`. Повтор — через 5 минут и по `recheck(.runner)`.
Без `--cursor-agent` демон Cursor не вызывает. `--approve-mcps` не включён. Платный `-p`, каталог при отсутствии логина, launchd login и MCP preflight не выполнены.
Установленный CLI `2026.09.23-86fc751`: `--list-models` требует аутентификацию, `status` сообщает `Not logged in`.

## Backend: BE-14 каталог моделей

[PR #80](https://github.com/imedfan/kaban/pull/80) влит в `codex/be-07-cursor-driver` и ещё не принят в main — [каталог моделей](development/backend-model-catalog-2026-10-06.md).
`auto` отвергается в YAML и в `setModelOverride`. Override хранится отдельно от версии pipeline и меняет только свою задачу и стадию.
`--list-models` принимается только как строки `id<TAB>name`. Иной непустой текст, включая ошибку аутентификации, не заменяет сохранённые строки.
Новая незапрещённая модель получает `needsReview`. Исчезнувший id блокирует только стадии, которые его используют.
Неизвестное или неоднозначное фактическое имя даёт `model_unconfirmed` и не выдумывает совпадение. Известное другое имя останавливает run как `model_substituted`, не списывает попытку и не считается успехом. Флаги переживают reopen.
Остановка процесса до первого инструмента на этой машине не наблюдалась: CLI не залогинен, платный `-p` не запускался. Process-pass по-прежнему не запускает Cursor.

## Backend: BE-15 лимиты и тихий выход

[PR #81](https://github.com/imedfan/kaban/pull/81) влит в `codex/be-14-model-catalog` и ещё не принят в main — [лимиты](development/backend-limit-handling-2026-10-06.md).
Известный лимит освобождает только этот run и пишет флаг в той же транзакции. Соседний run доигрывает. Om usage не блокирует cm; unknown usage блокирует Мак. Попытка и `runsSinceHuman` не списываются. Cooldown 15/30/60 переживает reopen; `resumeAfterRateLimit` снимает только rate limit. `quota=nil` не считается 100% свободно.
Тихий exit ждёт пробу: одна запись на модель, не чаще 10 минут, без `cursor-agent -p` и без обычного рестарта. Неизвестный текст остаётся одной редактированной строкой ленты. Платный `-p` не запускался.

## Backend: BE-09 MCP-сервер доски

[PR #82](https://github.com/imedfan/kaban/pull/82) влит в `codex/be-15-limit-handling` и ещё не принят в main — [MCP-сервер](development/backend-mcp-server-2026-10-06.md).
Пять инструментов слушают только `127.0.0.1`. Токен run передаётся в `KABAN_RUN_TOKEN` и в базе хранится как SHA-256. Чужой, отозванный и токен прошлого run не меняют задачу. Подмена `taskId` отклоняется. Повтор `complete_stage` не создаёт второй переход: задача входит в `gating` и получает `.runGates`, не следующую стадию и не Done. Нелегальный `return_to_stage` отклоняется. `request_human` освобождает слот. Notices уходят только адресату.
`listProjectMcpServers` и `setProjectMcpAllowlist` остаются неподдержанными. Обычный запуск демона сервер не держит. `/git/check` добавлен в BE-12 на том же loopback-сервере.

## Backend: BE-10 изоляция MCP

[PR #83](https://github.com/imedfan/kaban/pull/83) влит в `codex/be-09-mcp-server` и ещё не принят в main — [изоляция MCP](development/backend-mcp-isolation-2026-10-06.md).
Чужой или нечитаемый `mcp list` блокирует старт и не включает `--approve-mcps`. Сервер вне allowlist даёт предупреждение и не попадает в конфиг. Токен в файле только как `${env:KABAN_RUN_TOKEN}`. Подмена `.cursor/mcp.json` снимается до пустого diff.
Профиль запрещает прямую запись и `/usr/bin/git config` в `.git` клона. Это не гарантия изоляции: CLI остаётся вне профиля, чтение широкое, токен CLI не спрятан. Установленный CLI не залогинен, поэтому auth, сборка и MCP в реальном профиле не подтверждены.

## Backend: BE-11 гейты и передача стадии

[PR #84](https://github.com/imedfan/kaban/pull/84) влит в `codex/be-10-mcp-isolation` и ещё не принят в main — [гейты стадий](development/backend-stage-gates-2026-10-06.md).
`complete_stage` входит в `gating`. `--stage-pass` исполняет hooks, гейты, проверку результата и один commit и не запускает Cursor. Зелёный exit без final call стадию не закрывает. Красный гейт агента остаётся на том же клоне; красная gate-стадия возвращает в coding-стадию и не повторяется на месте. Возврат несёт конкретные issues, новый заход обнуляет attempts. Replay не пишет второй commit и не запускает hook снова. Пайплайн доходит до Human Review.
Проверка результата в этом инкременте читает только грязь read-only. Грязное дерево обычной стадии для этой проверки считается чистым. Подозрительные файлы и инциденты — BE-13. Merge остаётся BE-17. `/git/check` — BE-12.

## Backend: BE-12 git-разрешения

Открытый инкремент [PR #85](https://github.com/imedfan/kaban/pull/85) поверх `codex/be-10-mcp-isolation`, ещё не принят в main — [git-разрешения](development/backend-git-grants-2026-10-06.md).
`/git/check` и shim разрешают git только после ответа демона. Разрешение одноразовое и совпадает с argv целиком. Условный override проверяет сервер. Доставка notice grant не тратит. Пятый отказ run останавливает задачу без списания попытки. `done` и `cancel` истекают grant и оставляют argv. Cursor rules содержат только жёсткие команды.
Дополнительный запрет виден следующим run. Автокоммит YAML не делается, production `updatePipeline` не поддержан. Прямой `/usr/bin/git` shim обходит. Подозрительные файлы — BE-13, merge — BE-17.

## Backend: BE-13 подозрительные файлы и инциденты

Открытый инкремент [PR #86](https://github.com/imedfan/kaban/pull/86) поверх `codex/be-12-git-grants`, ещё не принят в main — [инциденты](development/backend-incidents-2026-10-06.md).
После run демон сравнивает refs, tags и `config` основного репозитория со снимком prepare, затем `.kaban/` и предка task branch. Нарушение откатывает git, открывает durable incident и ставит `waiting_human: incident`. Попытка не списывается, следующий tick run не начинает. `incidentOpened`/`incidentResolved` и `projectUpdated` несут один `commandId`. Снимок суммирует `ProjectSummary.openIncidentCount`. Клиент не увеличивает счётчик по предметным событиям. `projectRemoved` пересчитывает сумму.
Подозрительные файлы ищутся после зелёных гейтов. Стандарт смотрит зафиксированный diff, strict — ещё и незакоммиченное. `.cursor/mcp.json` возвращается к `main` и в набор не входит. `answerHuman` и `requestChanges` набор не принимают. `retryStage`, `moveTask`, `cancelTask` и `reject` в стадию принимают его по UC-25. Чужой набор даёт `stale_suspicious_files`. Новый blob того же пути срабатывает снова. Принятие текущего набора продолжает отложенный переход без нового run.
Обычная грязь без read-only остаётся чистой. Откат git выполняется до записи инцидента: сбой записи не обещает exactly-once внешнего git. Merge и production `updatePipeline` не входят в инкремент.

## Backend: BE-16 логи запусков

Открытый инкремент [PR #87](https://github.com/imedfan/kaban/pull/87) поверх `codex/be-13-incidents`, ещё не принят в main — [логи запусков](development/backend-run-logs-2026-10-06.md).
`readLog` отдаёт нормализованные события по смещению. Повтор смещения не дублирует и не пропускает строки. Нет файла или строки — `log_unavailable`, не пустая успешная страница. Префикс старше 1024 событий не перенумеровывается: чтение до него — `log_offset_expired`. `--log-pass` печатает ту же страницу и не запускает Cursor.
Секреты и `KABAN_RUN_TOKEN` вырезаются до записи лога, артефакта, вопроса, ответа и резюме. Снимок и detail больше 8 МиБ возвращают `snapshot_too_large` и `detail_too_large`; сохранённый текст не укорачивается. `getRunHistory` остаётся отдельным ответом. Медленное чтение лог не удаляет, и планировщик продолжает следующий tick.
Файл `Logs/<run-id>.jsonl` не откатывается вместе с SQLite. Пропавший файл — `log_unavailable`, даже если строки остались. Это не exactly-once файла. Очередь локального слияния — BE-17.

## Backend: BE-17 очередь локального слияния

Ветка `codex/be-17-local-merge` поверх `codex/be-16-run-logs`, ещё не принята в main — [очередь слияния](development/backend-merge-queue-2026-10-06.md). Pull request ещё не открыт.
Один merge на проект, в порядке одобрения. `--merge-pass` забирает ветку task clone, перебазирует её на свежий `main` во временном клоне, повторяет гейты и fast-forward'ит ref только когда `main` совпал с tip. Cursor этот проход не запускает. Обычный запуск демона `main` не двигает.
Dirty checkout с пересечением путей даёт `blocked: main_dirty` и `merge_blocked` без смены байтов, index и worktree. Сдвиг `main` между rebase и update возвращает фазу в rebase и не затирает чужой commit. Crash после fast-forward и до receipt сверяется с git и не делает второй `update-ref`. Это не exactly-once внешнего git. Конфликт возвращает в coding-стадию и снова требует Human Review; сверх лимита задача ждёт `conflict_limit`. Отмена queued merge не пишет её файл в `main`.

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

## Backend: BE-18 recovery

Штатный host восстанавливает физические процессы/gates, MCP, WIP и git effects
до запуска scheduler. PID reuse не сигналится; restart не списывает попытку.
[Контракт и проверки](development/backend-daemon-recovery-2026-10-06.md).
BE-18 пока в ветке, не в main; runtime ручных действий и упаковка следуют отдельно.
