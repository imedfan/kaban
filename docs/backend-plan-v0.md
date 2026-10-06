# Kaban: рабочий план бэкенда

Состояние реализации — [current-state](current-state.md). Технические требования —
[архитектура](architecture-v0.md), пользовательское поведение — [спецификация](kaban-mvp-features-usecases.md).
Старый план сохранён в [архиве](archive/2026-10-04/backend-plan-v0.md).

## Текущая база

Срез 6 октября 2026: BE-01–04 приняты в main (#71–74), проверенная база —
`4e25ca3`. Следующий backend-инкремент — BE-05; App пока использует mock.

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
Эти команды обслуживают managed fake; production Backlog/lifecycle/pipeline
подключены в BE-02/03 ниже; production task-control и scheduler добавлены в BE-04.

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
использует polling глобального журнала. Host выполняет recovery; BE-04 добавляет
scheduler loop, внешний executor и приложение ещё не подключены.

Порученная очередь — [BE-01–20](development/backend-mvp-tasks.md). BE-01 расширяет
контракт replacement/session, эфирного потока, log pages, version-bound draft,
Cursor environment и WIP restore. Реализация backend-функций за этими контрактами
проверяется по capabilities, а не по наличию enum case; границы —
[BE-01](development/backend-wire-contracts-2026-10-05.md). Принятый в PR #72
[BE-02](development/backend-project-lifecycle-2026-10-05.md): реальные Git roots,
author/canonical identity, template-only commit, durable recovery intent, missing-folder
observer, relink и logical removal/history. Production Backlog хранится даже без
валидного YAML.

[BE-03](development/backend-pipeline-storage-2026-10-05.md) добавляет committed
asset snapshots, валидные pipeline_version, source-bound draft/apply, isolated
`.kaban/` commit и восстановление файлового эффекта. Startup/recheck/observer
подхватывают manual main, отдельные working issues не меняют committed правила.
Immutable RunSpec и отложенный stage exit сохраняют текущую попытку при invalid
main; полный production scheduler добавлен в BE-04 ниже, внешний executor ещё не подключён.

[BE-04](development/backend-full-scheduler-2026-10-05.md) допускает все stage kinds
production-пайплайна, сохраняет RunSpec/outbox и weighted cursor в одной транзакции.
Agent slots отделены от gate/merge WIP и human admission. Host будится по командам,
observer и секундному timer; pass/tick ограничены, idle receipts не накапливаются.
Durable scheduler inputs предоставляют границу будущим model/quota/environment
producers; реальные CLI/пул/остаток не симулируются. Task-control/Human Review wire
команды доступны production-задачам. Claim/lease/receipt — BE-05 ниже; клоны и процессы —
BE-06–08, gates/hooks — BE-11, merge — BE-17.

[BE-05](development/backend-effect-execution-2026-10-06.md) добавляет fencing, lease,
external fact и receipt к существующим effect id. Сверка finished fact и receipt
даёт один переход. Повторный claim без факта не обещает exactly-once процесса.
Настоящий результат не проходит через `deliverFake`. Opt-in `--effect-pass`
подтверждает lifecycle effects только после commit. Process group добавлен в BE-08. Драйвер Cursor — BE-07 ниже. Каталог моделей — BE-14 ниже.

[BE-06](development/backend-task-clones-2026-10-06.md) создаёт `git clone --local` и ветку задачи
после commit плана. Параллельные задачи получают разные refs, config и cwd. Частичный каталог
занимает тот же путь и не порождает второй run. `keepBranch` пишет архивный ref, иначе его нет.
Удаление проверяет, что путь — записанный клон внутри workspace, и не трогает копию пользователя.
WIP save/restore человеком остаётся BE-18/19.

[BE-08](development/backend-process-control-2026-10-06.md) запускает переданный `--runner` в отдельной process group
и хранит pid, pgid и время рождения. Пауза, перенос и отмена останавливают только группу этой задачи.
Exit 0 с выводом и без final call даёт `no_final_call` и не двигает стадию. Тихий exit на этом срезе — BE-15: `retry_wait(.silentExit)` без списания и без нового обычного старта.
Crash и timeout пишут WIP ref внутри клона и откатывают его. `gate_failed` и `no_final_call` клон сохраняют.
Повторный stop не сигналит чужую группу. Cursor не запускается. Обрыв между spawn и записью строки не обещает exactly-once.

[BE-07](development/backend-cursor-driver-2026-10-06.md) разбирает stream-json, требует явную модель и не подставляет session id.
`recheck(runner)` и пятиминутный срок ставят `runner_unavailable`, если файл не найден или status сообщает logout.
`--cursor-agent` только записывает путь; без него демон Cursor не вызывает. Платный запуск и каталог без логина не входят в этот инкремент.

[BE-14](development/backend-model-catalog-2026-10-06.md) принимает каталог только из строк `id<TAB>name`, отвергает `auto` и сверяет display name с каталогом. Неизвестный текст не затирает строки. Остановка до первого инструмента на этой машине не наблюдалась.

[BE-15](development/backend-limit-handling-2026-10-06.md) классифицирует лимитный текст, пишет cooldown и usage-флаг в транзакции `apply` и не списывает попытку. Om не блокирует cm. Unknown usage блокирует Мак. `quota=nil` не означает свободный остаток. Проба после тихого выхода — одна строка на модель не чаще 10 минут и не запускает `-p`.

[BE-09](development/backend-mcp-server-2026-10-06.md) поднимает пять инструментов доски на `127.0.0.1`. Токен run живёт в окружении процесса, в базе остаётся хеш. `complete_stage` входит в `gating` один раз. Инкремент ещё не в main.

[BE-10](development/backend-mcp-isolation-2026-10-06.md) блокирует чужой или нечитаемый `mcp list`, не передаёт `--approve-mcps` и возвращает `.cursor/mcp.json` к базе. Профиль записи проверен на `/usr/bin/git` и прямой записи. Токен CLI этот профиль не изолирует. Auth в реальном профиле не подтверждена. PR #83 влит в `codex/be-09-mcp-server` и ещё не в main.

[BE-11](development/backend-stage-gates-2026-10-06.md) исполняет гейты, hooks и один commit стадии после `complete_stage`. Зелёный exit без final call стадию не двигает. Красный гейт агента остаётся на том же клоне; красная gate-стадия возвращает в coding-стадию. Replay не пишет второй commit и не запускает hook снова. Подозрительные файлы, `/git/check` и merge не входят в инкремент. Грязное дерево без read-only для проверки результата считается чистым. PR #84 влит в `codex/be-10-mcp-isolation` и ещё не в main.

[BE-12](development/backend-git-grants-2026-10-06.md) проверяет argv на `/git/check` и тратит одноразовый grant в той же записи. Условный override остаётся на сервере. Доставка не равна потреблению. `done` и `cancel` истекают grant. Cursor rules не содержат настраиваемый запрет. Автокоммит YAML не делается. Подозрительные файлы и merge не входят в инкремент. PR #85 открыт поверх `codex/be-10-mcp-isolation` и ещё не в main.

[BE-13](development/backend-incidents-2026-10-06.md) после run сравнивает refs, tags и `config` основного репозитория со снимком prepare, проверяет `.kaban/` и предка task branch, затем сканирует подозрительные файлы. Инцидент и `projectUpdated` пишутся одной командой. Клиент не считает инциденты по предметным событиям. Принятие точного набора продолжает отложенный переход без нового run. Обычная грязь без read-only остаётся чистой. Откат git происходит до записи и не обещает exactly-once. PR #86 открыт поверх `codex/be-12-git-grants` и ещё не в main. Merge остаётся BE-17.

[BE-16](development/backend-run-logs-2026-10-06.md) хранит нормализованные события запуска и читает их по смещению. Удалённый лог — `log_unavailable`, обрезанный префикс — `log_offset_expired` без перенумерации. Секреты вырезаются до записи. Снимок и detail сверх лимита сообщения отвечают явной ошибкой и не урезают сохранённый текст. Медленный читатель не останавливает планировщик. PR #87 открыт поверх `codex/be-13-incidents` и ещё не в main. Файл JSONL транзакцией не откатывается. Следующий пункт очереди — BE-17.

## Следующие результаты

1. Подключение приложения к durable источнику через готовый transport: replacement
   snapshot, pending commands/retry при reconnect и видимые состояния соединения.
   Отдельно проверить подписанный Mach service в составе бандла.
2. Оставшиеся wire-команды: WIP restore, среда и интеграция settings.
   Подозрительные файлы и инциденты — BE-13, [PR #86](https://github.com/imedfan/kaban/pull/86) открыт поверх `codex/be-12-git-grants` и ещё не в main.
   Каталог — BE-14, лимиты — BE-15; оба инкремента ещё не в main.
3. Cursor CLI поверх открытых клонов и process group. Exactly-once внешнего
   процесса не следует из SQLite-транзакции.
4. Квота, реальные CLI fixtures и подтверждённая изоляция токена CLI. `/git/check` — BE-12, [PR #85](https://github.com/imedfan/kaban/pull/85) открыт поверх `codex/be-10-mcp-isolation` и ещё не в main. Preflight и профиль записи — BE-10 и ещё не в main. Auth в реальном профиле не подтверждена.
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
