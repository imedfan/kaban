# Kaban: текущее состояние

Срез 5 октября 2026. Kaban — основной проект Артёма. Разработка не ограничена
ролью «второй команды»; действующие правила — [contributing](contributing.md)
и [AGENTS.md](../AGENTS.md). Документы и оригиналы дизайна доступны в Git.

## База этого среза

Проверенная после git fetch база реализации: `origin/main` —
`ff74c43` (приняты #63–72, включая native UI #67, transport #70, BE-01 #71 и BE-02 #72).
BE-03 ниже подготовлен в `codex/backend-pipeline-storage` от этой базы ([PR #73](https://github.com/imedfan/kaban/pull/73), открыт).
Локальная ветка с именем main
может быть старее origin/main; перед новой задачей проверь refs и diff.
Этот документ описывает код базы и явно отмеченный рабочий backend-инкремент.

## Что есть в основном коде

| Область | Реализовано | Граница |
|---|---|---|
| Protocol | Типизированные команды, snapshot/details, события, settings, optional Markdown body, legacy decoding | Наличие DTO не означает готовый транспорт |
| Kit | YAML/pipeline validation, git-policy, автомат, retry/return/pause rules | Не является процессом демона |
| DaemonCore | GRDB store, миграции v1–v5, durable state/journal/effects, wire-команды, project lifecycle, pipeline apply/recovery/RunSpec, bounded fake driver и scheduler | Production Backlog и версии пайплайна; запуск задач и task effects ещё fake |
| Daemon/Transport/CLI | Host с эксклюзивной lease БД, XPC listener/client, snapshot/catch-up/live polling, reconnect/resync, kabanctl; capabilities, session/ephemeral и observer папок/пайплайнов | Transport/BE-01/BE-02 приняты #70–72; BE-03 рабочий инкремент. Без LaunchAgent packaging, проверки Developer ID и подключения App |
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
BE-01/BE-02 приняты в #71/#72; BE-03 реализован в текущем инкременте.
Следующий — BE-04 (production scheduler). BE-04–20 ещё не завершены.

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

Основное приложение остаётся на MockKabanClient. Host не запускает scheduler loop,
fake driver или внешние effects: этот инкремент проверяет транспорт и сохранение
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
archive/cleanup effects ждут executor BE-05/06. Production start/scheduler ещё
заблокированы; fake registration/driver не подменяют настоящее исполнение.
Pipeline apply/reload добавлен в BE-03 ниже. App остаётся на MockKabanClient.

## Backend: BE-03 версии пайплайна

Рабочий инкремент — [хранилище и проверки](development/backend-pipeline-storage-2026-10-05.md).
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
Production scheduling/процессы, gates и merge executor следуют в BE-04–08;
проверка завершения использует сохранённые invocation fixtures. App не подключён.

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
