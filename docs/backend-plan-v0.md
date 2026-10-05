# Kaban: рабочий план бэкенда

Состояние реализации — [current-state](current-state.md). Технические требования —
[архитектура](architecture-v0.md), пользовательское поведение — [спецификация](kaban-mvp-features-usecases.md).
Старый план сохранён в [архиве](archive/2026-10-04/backend-plan-v0.md).

## Текущая база

KabanKit содержит pipeline/YAML validation, git-policy и чистый TaskMachine.
KabanDaemonCore использует GRDB и содержит durable projects/tasks/settings/details,
миграции, journal/outbox, fake driver, scheduler и recovery. Store использует
существующие Protocol DTO; дополнительная копия контрактов не требуется.

Инкремент [durable wire-команд](development/backend-wire-commands-2026-10-05.md)
добавляет `KabanStore.execute(CommandEnvelope)`: create/edit/priority,
move/pause/resume/cancel/retry, Human Review/answer, детали/runs, ручные
паузы, настройки и metadata зарегистрированного проекта. Оригинальный запрос
и ответ сохраняются в additive v3; replay предшествует ID/time generation.
Domain refusal сохраняется без перехода; сбой БД откатывает всё действие.
Wire-приёмник пока обслуживает только зарегистрированные managed fake проекты.

Managed fake engine — ограниченная portable вертикаль. Четырёхстадийный fake pipeline
допускается узким внутренним исключением merge_count; общий production-валидатор
и PipelineSummary продолжают сообщать ошибку. Эффекты git/process симулируются.
Поддержка этих данных не доказывает готовность живого runtime.

Матрица HC, транзакционные ожидания и границы — [m1-headless-contract](development/m1-headless-contract.md).
Исторический интеграционный результат — [m1-report](development/m1-report-2026-10-04.md);
новая правка проверяется на собственном HEAD.

Транспортный инкремент [daemon/CLI](development/backend-daemon-transport-2026-10-05.md)
добавляет единый DaemonService, bounded journal pages, monotonic seq при retention,
XPC адаптеры macOS 26, reconnect/resync клиент и kabanctl. Live subscription пока
использует polling глобального журнала. Host выполняет recovery, но ещё не запускает
scheduler/executor loop; приложение не подключено.

Порученная очередь — [BE-01–20](development/backend-mvp-tasks.md). BE-01 расширяет
контракт replacement/session, эфирного потока, log pages, version-bound draft,
Cursor environment и WIP restore. Реализация backend-функций за этими контрактами
проверяется по capabilities, а не по наличию enum case; границы —
[BE-01](development/backend-wire-contracts-2026-10-05.md). Следующий инкремент BE-02
подключает production lifecycle проектов. В текущем инкременте —
[BE-02](development/backend-project-lifecycle-2026-10-05.md): реальные Git roots,
author/canonical identity, template-only commit, durable recovery intent, missing-folder
observer, relink и logical removal/history. Production Backlog хранится даже без
валидного YAML; реальное исполнение/scheduler и apply pipeline ещё не подключены.

## Следующие результаты

1. Подключение приложения к durable источнику через готовый transport: replacement
   snapshot, pending commands/retry при reconnect и видимые состояния соединения.
   Отдельно проверить подписанный Mach service в составе бандла.
2. Production lifecycle проектов/pipelines и оставшиеся wire-команды: add/remove/relink,
   pipeline validation/replacement, model override, files/incidents и среда.
3. Внешний executor с claim/lease, процессами Cursor, git-клонами и гейтами.
   Exactly-once внешних действий не следует из SQLite-транзакции.
4. MCP/git shim, квота, реальные CLI fixtures и целевые isolation-спайки.
5. Упаковка LaunchAgent, регистрация, подпись и нотаризация в соответствующей задаче.

Сначала проверяется небольшой сквозной сценарий через те же DTO/events, которые
потребляет UI. Состояние, journal и outbox изменяются атомарно; внешний эффект
выполняется после commit и подтверждается durable receipt.

## Проверка

Поведение автомата — сценарии и nearby Kit suites. Store/scheduler — транзакции,
reopen/migration, повтор commands/effects/ticks, fairness/WIP/admission и stale results.
Полный пакет: `KABAN_SCENARIOS=Scenarios/M1 swift test`.

Пауза Мака/проекта блокирует новый admission/execution, не убивает текущие run.
Пауза задачи — отдельная команда. Human admission удерживается до stage exit;
уменьшение WIP не выталкивает уже допущенные задачи. UI получает authoritative
StageLoad/ProjectSummary; эти расчёты не дублируются в приложении.

Linux CI использует Swift 6.1 и SQLite headers. macOS/Xcode/App проверяются отдельно.
Исследования и синтетический Seatbelt probe не являются доказательством production isolation.
