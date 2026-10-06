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
BE-07 открыт в [PR #79](https://github.com/imedfan/kaban/pull/79) поверх #78. BE-14 открыт в [PR #80](https://github.com/imedfan/kaban/pull/80) поверх #79 и ещё не принят в main. BE-15 собран на ветке `codex/be-15-limit-handling` поверх #80; pull request ещё не открыт и в main не принят.
Локальная ветка с именем main
может быть старее origin/main; перед новой задачей проверь refs и diff.
Этот документ описывает код принятой базы и инкременты BE-06, BE-08, BE-07, BE-14 и BE-15, которые ещё не в main. Отчёты development фиксируют проверки
своих инкрементов, а не новый прогон на текущем HEAD.

## Что есть в основном коде

| Область | Реализовано | Граница |
|---|---|---|
| Protocol | Типизированные команды, snapshot/details, события, settings, optional Markdown body, legacy decoding | Наличие DTO не означает готовый транспорт |
| Kit | YAML/pipeline validation, git-policy, автомат, retry/return/pause rules, POSIX process group | Spawn и stop сами не являются циклом демона |
| DaemonCore | GRDB store, миграции v1–v12, durable state/journal/effects, claim/lease/receipt, клоны задач, process group локального runner, проверка runner, каталог моделей и override, лимитные флаги и проба модели, wire-команды, project lifecycle, pipeline apply/recovery/RunSpec, полный production scheduler и bounded fake driver | Production result не идёт через `deliverFake`. `--cursor-agent` проверяет runner и каталог и не запускает `-p`. Process group исполняется только с `--process-pass`. Проба после тихого выхода не запускает `cursor-agent -p` |
| Daemon/Transport/CLI | Host с эксклюзивной lease БД, recovery effect leases, opt-in `--effect-pass`, `--clone-pass` и `--process-pass`, XPC listener/client, snapshot/catch-up/live polling, reconnect/resync, kabanctl; capabilities, session/ephemeral, observer и scheduler loop | Transport/BE-01–04 приняты #70–74. `--effect-pass` не запускает Cursor или git. `--clone-pass` не запускает Cursor. `--process-pass` запускает только переданный `--runner` и не запускает Cursor. Без LaunchAgent packaging, проверки Developer ID и подключения App |
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
BE-05 принят в main (#76, `ea02f0c`). BE-06 и BE-08 влиты в родительские ветки и ещё не в main. BE-07 открыт (#79). BE-14 открыт (#80) поверх #79 и ещё не принят в main; остановка до первого инструмента не проверена. BE-15 собран поверх #80; pull request ещё не открыт и в main не принят. Платный пробный `-p` не запускался. Следующий в очереди — BE-09. BE-09–13 и BE-16–20 ещё не завершены.

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

Открытый инкремент [PR #79](https://github.com/imedfan/kaban/pull/79) поверх #78, ещё не принят в main — [драйвер Cursor CLI](development/backend-cursor-driver-2026-10-06.md).
Парсер NDJSON не обрывает run на неизвестном событии, битой или слишком длинной строке. Модель обязательна: пустое значение, `auto` и placeholder отклоняются до запуска.
`--resume` передаётся только с уже проверенным session id и вместе с `--model`. Без него новая сессия сохраняет переданный контекст и не получает выдуманный id.
Отсутствующий или неисполняемый файл и status «not logged in» ставят `runner_unavailable`. Повтор — через 5 минут и по `recheck(.runner)`.
Без `--cursor-agent` демон Cursor не вызывает. `--approve-mcps` не включён. Платный `-p`, каталог при отсутствии логина, launchd login и MCP preflight не выполнены.
Установленный CLI `2026.09.23-86fc751`: `--list-models` требует аутентификацию, `status` сообщает `Not logged in`.

## Backend: BE-14 каталог моделей

Открытый инкремент [PR #80](https://github.com/imedfan/kaban/pull/80) поверх #79, ещё не принят в main — [каталог моделей](development/backend-model-catalog-2026-10-06.md).
`auto` отвергается в YAML и в `setModelOverride`. Override хранится отдельно от версии pipeline и меняет только свою задачу и стадию.
`--list-models` принимается только как строки `id<TAB>name`. Иной непустой текст, включая ошибку аутентификации, не заменяет сохранённые строки.
Новая незапрещённая модель получает `needsReview`. Исчезнувший id блокирует только стадии, которые его используют.
Неизвестное или неоднозначное фактическое имя даёт `model_unconfirmed` и не выдумывает совпадение. Известное другое имя останавливает run как `model_substituted`, не списывает попытку и не считается успехом. Флаги переживают reopen.
Остановка процесса до первого инструмента на этой машине не наблюдалась: CLI не залогинен, платный `-p` не запускался. Process-pass по-прежнему не запускает Cursor.

## Backend: BE-15 лимиты и тихий выход

Инкремент на ветке `codex/be-15-limit-handling` поверх #80, pull request ещё не открыт и в main не принят — [лимиты](development/backend-limit-handling-2026-10-06.md).
Известный лимит освобождает только этот run и пишет флаг в той же транзакции. Соседний run доигрывает. Om usage не блокирует cm; unknown usage блокирует Мак. Попытка и `runsSinceHuman` не списываются. Cooldown 15/30/60 переживает reopen; `resumeAfterRateLimit` снимает только rate limit. `quota=nil` не считается 100% свободно.
Тихий exit ждёт пробу: одна запись на модель, не чаще 10 минут, без `cursor-agent -p` и без обычного рестарта. Неизвестный текст остаётся одной редактированной строкой ленты. Платный `-p` не запускался.

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
