# Kaban: архитектура MVP (черновик v0.10.2)

Автор: Kaban Architector Bot · 3 октября 2026 · статус: на обсуждение, до утверждения Артёмом

Решения, на которых стоит документ: macOS 26 минимум; Swift-демон через launchd и тонкий SwiftUI-клиент; одна SQLite через GRDB на все проекты; агент в MVP только Cursor CLI; MCP доски по HTTP на loopback с токеном на запуск; Developer ID без App Store; изоляция задачи через `git clone --local`; слияние локально в `main`; бюджета в долларах в MVP нет; стадии абстрактные и задаются `.kaban/pipeline.yaml`; в Human Review сводка изменений и «Открыть в Cursor» вместо своего диффа.

**Этот документ — единственный источник набора статусов (раздел 3.2) и XPC-команд (раздел 5).** Спека фич и юзеркейсов на них ссылается.

Пометка **[спайк N]** — проверяем прототипом на Маке до старта разработки (раздел 14).

## 1. Процессы и границы

```mermaid
flowchart LR
  subgraph App["Kaban.app (SwiftUI, Developer ID)"]
    UI["Доска + MenuBarExtra"]
  end
  subgraph D["KabanAgent (LaunchAgent, SMAppService.agent)"]
    XPC["XPC Mach-сервис\nкоманды, снимок, события"]
    SCH["Планировщик\n(тик + события)"]
    SM["Конечный автомат\n(чистая логика)"]
    RUN["Runner: процессы\ncursor-agent в Seatbelt"]
    HTTP["Loopback HTTP 127.0.0.1\nMCP доски + /git/check"]
    GIT["Git: клоны задач,\nочередь слияния"]
    DB[("SQLite WAL\nGRDB")]
    LOG[("Логи run\nJSONL")]
  end
  CA["cursor-agent -p\nstream-json"]
  GW["обёртка git\n(первая в PATH)"]
  MAIN[("Основной репозиторий\nпроекта (main)")]
  CL[("Клоны задач\ngit clone --local")]

  UI <-->|XPCSession, Codable| XPC
  XPC --> SM
  SCH --> SM
  SM --> DB
  SCH --> RUN
  RUN -->|spawn, stdout| CA
  RUN --> LOG
  CA -->|MCP tools| HTTP
  CA --> GW
  GW -->|/git/check| HTTP
  HTTP --> SM
  CA --> CL
  GIT -->|clone, fetch ветки задачи,\nff-merge| MAIN
  GIT --> CL
```

- **Kaban.app** — тонкий клиент: рисует доску, шлёт команды, получает снимок и события. Закрытие окна или падение UI не влияет на работающие задачи. Приложение стоит в автозапуске как менюбар-аппка и шлёт уведомления (раздел 12).
- **KabanAgent** — демон внутри бандла (`Contents/Library/LaunchAgents/…plist`), регистрируется через `SMAppService.agent`, объявляет `MachServices`. Вся логика и всё состояние здесь, единственный писатель в БД.
- **cursor-agent** — внешний процесс на каждую попытку стадии, свой process group, cwd = клон задачи, запуск внутри профиля Seatbelt.
- `kabanctl` — CLI поверх того же XPC, для отладки и скриптов, с первого дня.

## 2. Swift-пакет `KabanKit`

| Модуль | Что внутри | Платформа |
|---|---|---|
| `KabanModel` | Task, Stage, Pipeline, Run, статусы, причины; чистые функции: валидатор пайплайна, итоговая git-политика стадии, генератор маскота | macOS + Linux |
| `KabanStateMachine` | `reduce(state, command) -> (state, [effect])`, WIP, лимиты возвратов, ретраи | macOS + Linux |
| `KabanProtocol` | XPC: команды, ответы, снимок, события с `seq` | macOS + Linux (Codable) |
| `KabanStore` | GRDB: схема, миграции, журнал | macOS + Linux |
| `KabanScheduler` | цикл планировщика, справедливый обход проектов, с фейковым драйвером | macOS + Linux |
| `KabanAgentDrivers` | `AgentDriver` + `CursorCLIDriver` (аргументы, парсер stream-json → `AgentEvent`) | macOS + Linux |
| `KabanHTTP` | loopback-сервер: MCP доски и `/git/check` | macOS + Linux |
| `KabanGit` | клоны задач, fetch, rebase, ff-merge, diffstat, снимки refs | macOS + Linux |
| `KabanGitShim` (executable) | обёртка `git` для PATH агента | macOS |
| `KabanDaemon` (executable) | сборка всего, Seatbelt, launchd, XPC listener | macOS |
| `KabanApp` (Xcode) | SwiftUI | macOS |

Всё, кроме последних трёх, собирается и тестируется на общем Linux-компьютере, пока Мак не в сети.

## 3. Конечный автомат

### 3.1 Пайплайн из конфига

Автомат строится из `.kaban/pipeline.yaml`. В коде только **типы** стадий и правила статусов; набор, порядок и настройки стадий — из конфига. `Backlog → Dev → Test → AI Review → Human Review → Merge → Done` — шаблон по умолчанию.

| kind | Что делает | WIP | агент | гейты | возврат назад |
|---|---|---|---|---|---|
| `queue` | Backlog | нет | нет | нет | нет |
| `agent` | запуск харнеса | да | да | да | по `returns_to` |
| `gate` | только команды без ИИ (на доске — тонкая полоса) | да | нет | да | по `on_fail` |
| `human` | решение человека | опционально | нет | нет | да (любая предыдущая стадия) |
| `merge` | очередь слияния, ровно одна на пайплайн | 1 | нет | да (после rebase) | по `on_conflict` |
| `terminal` | Done | нет | нет | нет | нет |

```yaml
version: 1
board:                              # правила процесса проекта; ресурсы Мака здесь не задаются
  max_waiting_human: 3              # на проект
  bounce_limit_total: 5
  max_runs_per_task: 12             # только автоматические запуски, см. 3.2
workspace:
  warm_paths: [node_modules, .gradle]
  on_create: "npm ci --prefer-offline"
git:
  preset: standard                  # strict | standard | permissive
  allow: [status, diff, log, show, add, commit, "restore --staged"]
  deny:  [push, "reset --hard", remote, config, tag, "branch -D", "--force", "checkout main", "rebase main"]
stages:
  - id: dev                         # стабильный id, на него ссылается SQLite
    name: Разработка
    kind: agent
    display: { icon: hammer, color: blue, order: 2, collapsed: false, hidden: false }
    wip: 3
    priority: [returned, answered, fifo]
    agent:
      harness: cursor-cli
      model: <model-id>               # обязательно, явный id из `--list-models`; `auto` запрещён
      skill: .kaban/skills/dev.md
      permissions: write            # write | read-only
      mcp: [kaban]                  # сервер доски всегда; прочие MCP — только из белого списка проекта (9)
      env: { NODE_ENV: test }       # без секретов; секреты только по имени ключа Keychain
      workspace: task               # task | fresh-readonly
    git: { extend: [rebase], when: return_reason == merge_conflict }
    inputs: [task, handoff, return_issues, gate_output, git_grants]
    gates: ["./gradlew build", "./gradlew test"]
    on_success: test
    returns_to: []
    retry: { max_attempts: 3, backoff: [30s, 2m] }   # пауз на одну меньше, чем попыток; значения ждут решения Артёма
    timeouts: { stall: 10m, wall: 60m }
    hooks: { on_enter: null, on_exit: null }
    notify: [waiting_human]
  - id: test
    kind: agent
    on_success: ai-review
    returns_to: [{ stage: dev, limit: 3 }]
  # ...
```

**Источник правды — закоммиченный `main:.kaban/`.** Демон читает `git show main:.kaban/pipeline.yaml`, а не файл на диске, поэтому переключение ветки или незакоммиченная правка в рабочей копии человека правила не меняют. Копии в клонах задач игнорируются, а проверка результата (8.2) отклоняет любые изменения агента в `.kaban/`.

**Запись.**
- Из настроек UI: приложение атомарно пишет файл и вызывает `updatePipeline(projectId, contentHash)`. Демон синхронно валидирует и, если всё в порядке, автокоммитит `git commit --only -- .kaban/` под блокировкой очереди слияния проекта; ответ — либо новая версия, либо список `ValidationIssue`. Остальные правки человека в рабочей копии не трогаются.
- Ручная правка файла: FSEvents ловит изменение, демон валидирует и публикует состояние «есть незакоммиченные правки пайплайна» с результатом проверки. Молча не коммитим: в настройках кнопка «Применить» (тот же `updatePipeline`), либо человек коммитит сам.
- Новый проект без `.kaban/`: в диалоге добавления галочка «создать шаблон и закоммитить» (по умолчанию включена). Моделей по умолчанию нет: шаблон коммитится с пустыми `model:`, и проект сразу получает `unavailable: pipeline_invalid` со списком стадий без модели. Без закоммиченного пайплайна проект добавляется, но задачи не запускаются, на дорожке плашка «нет пайплайна». Задачи в Backlog создавать можно в обоих случаях.
- Чистая рабочая копия для добавления проекта не нужна.

**Валидация** (JSON Schema + семантика в `KabanModel`). Ошибки — `ValidationIssue { path: "stages[2].wip", code, message, severity }`, путь к полю для подсветки в настройках. `updatePipeline` некорректную версию не коммитит, «Сохранить» в UI при ошибках неактивна, черновик живёт только в редакторе. Если некорректная версия попала в `main` ручным коммитом, проект получает `unavailable: pipeline_invalid`: идущие runs доигрывают, новые не стартуют и задачи не переходят между стадиями, флаг гаснет сам, когда в `main` появляется корректная версия (правило «работаем на последней валидной» с v0.10 снято).
- `id` уникальны; одна `queue`-стадия входа, одна `merge`, есть `terminal`;
- `terminal` достижим по `on_success` из каждой стадии, циклов по `on_success` нет;
- `returns_to` указывает только назад по цепочке;
- **нельзя удалить стадию, в которой есть задачи в нетерминальном статусе** (включая `queued`);
- у **каждой** `agent`-стадии явная `model`, не `auto`; хоть одна стадия без модели делает некорректным весь пайплайн;
- `wip ≥ 1`, таймауты и лимиты в границах, пауз в `backoff` не больше `max_attempts − 1`; харнес из поддерживаемых; в `env` нет похожего на секреты.

Модель, которой нет в `model_catalog`, валидацию не ломает (каталог может отставать): она даёт флаг модели `unavailable` (3.2), а не ошибку пайплайна.

**Версии.** Валидная версия сохраняется снимком в `pipeline_version` (хэш, JSON). Задача при входе в стадию запоминает хэш, идущий run доживает по своему снимку, новые берут текущую. Урезание WIP ниже текущего числа задач никого не убивает, просто новые не стартуют. Уменьшение лимита возвратов ниже набранного — задача доходит стадию, на следующем возврате уходит к человеку.

### 3.2 Статусы (единый набор)

Задача всегда находится в стадии (`stage_id`) и имеет ровно один `status`. Отдельного `failed` нет: всё, что требует решения, это `waiting_human` с причиной.

| status | Смысл | Занимает WIP стадии | Считается в `max_waiting_human` |
|---|---|---|---|
| `queued` | ждёт слота в стадии (в Backlog — ждёт отправки в работу) | нет | — |
| `running` | идёт run агента | да | — |
| `gating` | идут гейт-команды (после `complete_stage`, в `gate`- и `merge`-стадиях) | да | — |
| `retry_wait` | пауза перед повтором (backoff или cooldown rate-limit) | да | — |
| `waiting_human` | нужен человек, см. `reason` | нет | да, кроме `reason = review` |
| `paused` | человек поставил на паузу эту задачу | нет | — |
| `blocked` | не может идти по внешней причине, см. `reason` | нет | — |
| `done` | дошла до `terminal` | нет | — |
| `cancelled` | отменена или отклонена человеком | нет | — |

Причины (`reason`, enum):
- `waiting_human`: `question` (агент вызвал `request_human`), `review` (задача в `human`-стадии), `retries_exhausted`, `bounce_limit`, `conflict_limit`, `run_limit` (превышен `max_runs_per_task`), `model_substituted` (Cursor ответил не той моделью, 6.4), `git_denials` (5 отказов политики за run), `incident` (проверка результата нашла нарушение), `invalid_result` (read-only стадия оставила изменения).
- `queued` (не статус ошибки, а подпись на карточке): `wip_full` («Ждёт места»), `quota_cm` / `quota_om` (остаток пула ниже порога, 7), `model_flag` (на модели стадии висит флаг). Задача с такой причиной не держит очередь: планировщик берёт следующую в стадии.
- `retry_wait`: `crash`, `stall_timeout`, `wall_timeout`, `no_final_call`, `gate_failed`; без списания попытки: `rate_limit` и `runner_auth` (ждут снятия глобального флага), `daemon_restart`, `silent_exit` (выход без единого вызова инструмента и без изменений, ждёт пробного запуска, 6.4).

**Счётчики.** Попытки (`max_attempts`) считаются в пределах одного захода в стадию и обнуляются при возврате или новом входе. `max_runs_per_task` считает все автоматические runs задачи, кроме тех, что не списывают попытку (`rate_limit`, `runner_auth`, `daemon_restart`, `silent_exit`, остановка по `model_substituted`); любое действие человека над задачей (`answerHuman`, `retryStage`, `moveTask`, `requestChanges`, `reject` в стадию) обнуляет его. Ретрай, упёршийся в квоту или флаг модели, освобождает WIP-слот и уходит в `queued` с причиной, попытку не списывает.
- `blocked`: `main_dirty` — только задача в голове очереди слияния, когда ff-merge упёрся в пересекающиеся правки человека.

Всё, что касается целого Мака или целого проекта, — **флаги планировщика**, а не статусы задач: задачи остаются `queued`, новые runs не стартуют, текущие доигрывают.

| Уровень | Флаг | Причины | Где показывается | Снимается |
|---|---|---|---|---|
| Мак | `paused` | `manual` | баннер над доской | `resumeAll` |
| Мак | `rate_limited` | — (короткий лимит, cooldown 15 → 30 → 60 мин) | баннер над доской | по времени или `resumeAfterRateLimit` |
| Мак | `usage_exhausted` | `unknown` (кончилась месячная квота, но неизвестно, какой пул) | баннер над доской с датой сброса | по `billingCycleEnd` или дате из текста ошибки; если дата неизвестна — пробный запуск раз в 6 ч или вручную |
| Пул | `usage_exhausted` | `cm`, `om` (известно, какой пул кончился) | баннер «Om исчерпан · N стадий» и знак в шапках столбцов на моделях этого пула | так же, как на уровне Мака |
| Мак | `runner_unavailable` | `agent_missing`, `agent_not_runnable` (не отвечает `--version`), `agent_not_logged_in`, `runner_auth` (run упал с ошибкой авторизации) | баннер над доской, «Проверить снова» | успешная проверка |
| Проект | `paused` | `manual` | шапка дорожки | `resumeProject` |
| Проект | `intake_paused` | `max_waiting_human` (только забор из Backlog) | шапка дорожки | автоматически |
| Проект | `unavailable` | `project_missing`, `no_pipeline`, `pipeline_invalid` (в т. ч. стадия без модели), `mcp_unexpected` (CLI видит MCP-сервер вне собранного конфига, 9) | шапка дорожки, «Проверить снова» | автоматически или `recheck` |
| Проект | `merge_blocked` | `main_dirty` | шапка дорожки + задача `blocked: main_dirty` | автоматически после очистки |
| Модель | `model_flag` | `unavailable` (пропала из `--list-models` или `resource_exhausted`), `substituted` (6.4) | тонкий баннер «Opus недоступен · N стадий» над доской и знак в шапках этих столбцов | проба на модели (одна на модель, не чаще раза в 10 мин) с ожидаемым именем в `init`, появление в каталоге или `clearModelFlag` |

Флаг модели останавливает только стадии с этой моделью; задачи на других моделях идут дальше.

Проверка раннера: при старте демона, раз в 5 минут и по `recheck`: бинарь по сохранённому пути, ответ `--version`, статус входа без запуска модели (какой командой — **[спайк 1]**). Реактивно: ошибка авторизации в run сразу включает `runner_unavailable: runner_auth` на весь Мак, а run уходит в `retry_wait: runner_auth` без списания попытки (бэк), чтобы разлогин за ночь не сжёг ретраи всей доски. Отдельно состояние карточки показывает бейджи, которые статусом не являются: счётчики возвратов (`2/3`), пересечение файлов с другой задачей, наличие неиспользованного git-разрешения.

У `run` свой статус: `starting → running → (succeeded | failed | killed)` и `end_reason` (те же значения, что причины `retry_wait`, плюс `completed`, `returned`, `asked_human`, `paused_by_human`, `moved_by_human`).

### 3.3 Переходы

| Команда / событие | Кто | Эффект |
|---|---|---|
| `start_run` | планировщик | `queued → running`, создаёт run |
| `complete_stage(summary, artifacts)` | агент (MCP) | `running → gating` |
| `gate_passed` / `gate_failed(output)` | демон | → `queued` следующей стадии / `retry_wait: gate_failed` |
| `return_to_stage(target, issues[])` | агент (MCP) | → `queued` целевой стадии, счётчик причины +1 |
| `request_human(question)` | агент (MCP) | → `waiting_human: question`, сессия сохраняется |
| `run_exited` без финального вызова | демон | → `retry_wait: no_final_call` |
| `timeout(stall|wall)`, `crash` | демон | убить process group, грязное состояние клона сохранить в `refs/kaban/wip/<run-id>` (внутри клона), откатить клон к последнему коммиту стадии, → `retry_wait` |
| `silent_exit` | демон | выход без вызовов инструментов и изменений → `retry_wait: silent_exit` без списания, пробный запуск на модели (6.4) |
| `model_mismatch` в `system/init` | демон | убить run до первого вызова инструмента, → `waiting_human: model_substituted`, флаг модели `substituted`, результат не принимается, попытка не списывается |
| `quota_below_threshold` перед стартом | планировщик | run не создаётся, задача остаётся/возвращается в `queued: quota_cm | quota_om` |
| превышен `max_runs_per_task` | демон | → `waiting_human: run_limit` |
| `rate_limit_detected` | демон | глобальный cooldown, этот run → `retry_wait: rate_limit` |
| исчерпаны `max_attempts` / лимит возвратов | демон | → `waiting_human` с причиной и сводкой |
| `answerHuman(text, requestId?)` | человек | из `waiting_human` с любой причиной → `queued` своей стадии с приоритетом `answered`, resume сессии с текстом (**[спайк 1]**). Это и ответ на вопрос, и «Замечание агенту»; если попытки или лимит возвратов исчерпаны, добавляется одна попытка |
| `approve` | человек, `human`-стадия | → `queued` следующей стадии (Merge) |
| `requestChanges(comments, target?)` | человек | → `queued` указанной стадии (по умолчанию первая agent), возврат в лимиты не входит |
| `reject(target, keepBranch?)` | человек | `target = cancel` → `cancelled`, как `cancelTask`; `target = <stage>` → в эту стадию |
| `pauseTask` / `resumeTask` | человек | убить текущий run без списания попытки, → `paused` / обратно `queued` |
| `moveTask(stage)` | человек | то же, что `requestChanges` без комментария; текущий run убивается без списания |
| `retryStage(grantAttempts?)` | человек | из `waiting_human` → `queued`, при необходимости добавить попыток |
| `cancelTask(keepBranch?)` | человек | → `cancelled`; текущий run убивается, клон удаляется. С `keepBranch` демон сначала забирает ветку задачи из клона в основное репо как `kaban/archive/<task-id>` и сразу добавляет этот ref в `refs_snapshot`; без флага в основном репо ничего не остаётся |

`complete_stage` никогда не двигает задачу сам: дальше её переводит демон после зелёных гейтов и проверки результата (8.2).

### 3.4 Планировщик (все проекты)

Два уровня настроек: процесс команды в `pipeline.yaml` (стадии, WIP, лимиты возвратов, `max_waiting_human`, git-политика) и ресурсы Мака в локальной БД (`max_concurrent_runs`, по умолчанию 4; вес проекта и личный максимум; маскот).

Флаги планировщика — таблица в 3.2. Очередь слияния своя у каждого проекта.

Цикл (по событию и по таймеру):
1. Reconciliation: сверить живые процессы с runs, обработать таймауты, разбудить `retry_wait`, у которых истёк backoff или cooldown.
2. Применить флаги планировщика (3.2). Текущие runs всегда доигрывают.
3. Кандидаты: в каждом активном проекте для каждой стадии со свободным WIP — первая задача по `priority` стадии; стадии от конца конвейера к началу.
4. Слоты делятся между проектами взвешенным круговым обходом (deficit round robin) с учётом личных максимумов; курсор обхода в БД.
5. Выбор и старт run — одна транзакция с проверкой WIP и глобального потолка.

## 4. Хранилище

`~/Library/Application Support/Kaban/kaban.sqlite`, WAL, один писатель. Во всех таблицах `project_id`.

- `project` — стабильный id, путь и bookmark папки, базовая ветка, вес, личный максимум, маскот, `available | missing`;
- `settings` — `max_concurrent_runs`, курсор обхода, состояние пауз и cooldown; опция квоты (выключена, согласие, время согласия), интервал опроса (1, 5, 15, 30 мин или своё), пороги Cm и Om (по умолчанию 10%);
- `pipeline_version` — снимки валидных версий;
- `task` — `stage_id`, `status`, `reason`, хэш версии пайплайна при входе в стадию, приоритет, `bounce_by_reason`, ветка, путь клона, `session_id` для resume;
- `run` — попытка: стадия, номер, pid, pgid, время старта процесса, запрошенная модель (id) и фактическое имя из `init`, `counts_toward_limits`, статус, `end_reason`, exit code, usage, путь к логу, счётчик git-отказов;
- `git_grant` — разовые git-разрешения (раздел 8.3);
- `incident` — `task_id`, `run_id`, вид нарушения (`refs_moved`, `tags_changed`, `config_changed`, `kaban_dir_changed`, `foreign_base`), что откатили, `opened_at`, `resolved_at`, `resolved_by_command`. Инцидент закрывается сам в той же транзакции, где человек выводит задачу из `waiting_human: incident` любой командой (`answerHuman`, `retryStage`, `moveTask`, `requestChanges`, `reject`, `cancelTask`);
- `refs_snapshot` — ожидаемые refs основного репозитория для проверки результата;
- `task_feed_item` — лента задачи (переходы, вопросы, отказы и разрешения git, инциденты, резюме); живёт столько же, сколько задача, и не обрезается вместе с журналом;
- `event` — append-only журнал синхронизации с глобальным `seq` (бывший `transition`): переходы задач, изменения проектов и настроек, применённые версии пайплайна, инциденты, git-отказы и разрешения. В `payload` — `commandId` команды-источника;
- `human_request`, `artifact` (резюме стадий, diffstat, вывод гейтов);
- `model_catalog` — `id`, `name` (отображаемое имя из `--list-models`), `pool`, `needs_review` («проверь пул»), `forbidden` (`auto`), `seen_at`, `missing_since`; сверяется с CLI при старте демона и раз в сутки;
- `model_pool_rule` — `pattern`, `pool` (`cm | om`), `source` (`builtin | user`); встроенное правило одно: `composer-*` → Cm, остальное → Om; ручные исключения Артёма;
- `model_flag` — `model_id`, `reason` (`unavailable | substituted`), `requested`, `actual?` (только при `substituted`), `fallback_model`, `since`, `last_probe_at`;
- `quota_sample` — время, `cm_percent`, `om_percent`, `billing_cycle_end`, число runs в пуле (для оценки среднего расхода);
- `project_mcp_allow` — белый список MCP проекта: имя сервера, источник (`project | personal`).

Каждая команда — одна транзакция: запись в `event` + обновление проекций. Логи stream-json — в `Logs/<run-id>.jsonl`, в БД путь и счётчики. Журнал `event` нужен только для досылки клиенту и обрезается (30 дней или N событий); история задачи берётся из `task_feed_item`, `artifact`, `run`, `git_grant`, `human_request` через `getTaskDetail` (раздел 5).

## 5. XPC-протокол

`XPCSession` / `XPCListener`, сообщения Codable из `KabanProtocol`. Listener принимает только клиента, подписанного нашим Team ID.

**Синхронизация.**
- `getSnapshot(projectIds?) -> Snapshot { seq, projects, pipelines, tasks, schedulerFlags, modelFlags, quota?, openIncidentCount }` — состояние доски на момент `seq` (карточки, без лент).
- `getTaskDetail(taskId) -> TaskDetail { seq, task, feed, runs, artifacts, gitGrants, gitDenials, humanRequests }` — всё для панели деталей из долговечных таблиц, не из журнала; дальше панель обновляется событиями этой задачи с `seq` больше полученного.
- `subscribe(fromSeq, projectIds?)` — досылка из `event` после `fromSeq`, затем живые события. Если `fromSeq` старше хранимого журнала — сигнал `resyncRequired`, клиент берёт снимок заново.
- Каждая команда несёт `commandId` (UUID от клиента); ответ содержит `commandId` и `seq` порождённого события, а журнальное событие — тот же `commandId` в `payload`. UI не делает оптимистичных переходов: карточка ждёт событие с этим `commandId`.

**Журнальные события** (имеют `seq`, переживают переподключение): изменения задач и их статусов, проекты, настройки, версии пайплайна, инциденты, git-отказы и разрешения, вопросы и ответы.
**Эфемерные** (без `seq`, при переподключении приходят текущим значением в снимке): `schedulerFlagsChanged` (все флаги из 3.2 с причинами и временем cooldown), `modelFlagsChanged`, `quotaUpdated { cm?, om?, billingCycleStart?, billingCycleEnd?, fetchedAt }` (`nil` — «нет данных», а не 0%), `modelCatalogChanged`, результат проверки раннера, результат валидации ручной правки пайплайна, прогресс run, живой лог.

**Журнальные события git:** `gitDenied { denialId, taskId, runId, argv, rule }`, `gitGrantCreated { grantId, denialId, argv, by }`, `gitGrantDelivered { grantId, runId, via: mcp_response | next_prompt }` (агент получил уведомление о разрешении), `gitGrantConsumed { grantId, runId }`, `gitGrantRevoked { grantId, by }`, `gitGrantExpired { grantId, reason: task_done | task_cancelled }`, `gitPolicyUpdated { projectId, scope, pipelineVersion }`.

**Журнальные события инцидентов:** `incidentOpened { incidentId, projectId, taskId, runId, kind, rolledBack }`, `incidentResolved { incidentId, by, commandId }`.

**Живой лог.** Отдельный поток `tailLog(runId, fromOffset)` отдаёт уже разобранные `AgentEvent` (сообщение, tool call, результат, ошибка, usage) батчами раз в 100–250 мс; так UI не зависит от формата конкретного харнеса. Путь к сырому JSONL есть в run для «Открыть сырой лог».

**Команды.**
- Проекты: `addProject(path, createTemplate)`, `removeProject`, `relinkProject(id, path)`, `listBranches(projectId)`, `detectGates(projectId)` (предложить гейты по файлам сборки), `setMascot`, `setProjectWeight(weight, maxRuns?)`.
- Пайплайн и политика: `updatePipeline(projectId, contentHash) -> PipelineVersion | [ValidationIssue]`, `validatePipeline(projectId, content)` (без записи, для живой проверки в настройках).
- Детали: `getTaskDetail(taskId)`.
- Задачи: `createTask`, `editTask` (только в `queued`/`waiting_human`/`paused`), `setPriority`, `moveTask(stage)`, `pauseTask`, `resumeTask`, `cancelTask(taskId, keepBranch = false)`, `retryStage(grantAttempts?)`, `setModelOverride(taskId, stageId, model)`.
- Человек: `answerHuman(taskId, text, requestId?)` (ответ на вопрос или «Замечание агенту» из любого `waiting_human`), `approve(taskId)`, `requestChanges(taskId, comments, target?)`, `reject(taskId, target, keepBranch = false)` (`keepBranch` учитывается только при `target = cancel`).
- Git: `allowGitOnce(denialId)`, `addDenialToPolicy(denialId, scope: .project | .stage(stageId))` (правка `.kaban/` через тот же путь, что `updatePipeline`), `revokeGitGrant(grantId)`.
- Планировщик: `pauseAll` / `resumeAll`, `pauseProject` / `resumeProject`, `resumeAfterRateLimit` (досрочно снять cooldown), `setMaxConcurrentRuns`.
- Среда: `checkEnvironment() -> { cursorAgentPath, version, authOK, gitVersion, sandboxOK, notificationsAuthorized }`, `recheck(scope: .runner | .project(id))` для кнопки «Проверить снова».
- Модели и квота: `listModels()` (каталог с пулами, без `forbidden`), `refreshModelCatalog()`, `setModelPoolRule(pattern, pool)` / `removeModelPoolRule`, `clearModelFlag(modelId)`, `setQuotaOptions(enabled, consent, pollInterval, thresholdCm, thresholdOm)`.
- MCP: `listProjectMcpServers(projectId)` (найденные в `.cursor/mcp.json` проекта и в личном конфиге), `setProjectMcpAllowlist(projectId, servers)`.
- Логи: `tailLog(runId, fromOffset)`, `getRunHistory(taskId)`.
- Инциденты: `listIncidents(projectIds?, state: .open | .all)` для раздела «Инциденты» в сайдбаре; отдельной команды «разобрать» нет.

Набор проектов на доске (упорядоченный список `projectId`, `BoardSetStore`) — состояние приложения, демону не нужно. Приложение подписывается на все проекты (`projectIds` = nil) и фильтрует на своей стороне, чтобы у скрытого проекта в сайдбаре оставались значки `waiting_human` и инцидентов.

## 6. Интеграция с Cursor

### 6.1 Драйвер
```swift
protocol AgentDriver {
  func makeInvocation(run: RunSpec) throws -> ProcessSpec   // argv, env, cwd
  func parse(line: Data) -> AgentEvent?
}
```
`CursorCLIDriver` — единственная реализация в MVP, протокол оставляет дорогу к Cursor SDK, Codex app-server, Claude и ACP.

Запуск (точные флаги — **[спайк 1]**): `cursor-agent -p --output-format stream-json --model <id> [--force] --approve-mcps "<prompt>"`, cwd = клон задачи, свой process group, внутри Seatbelt (8.2). `--model` передаётся **всегда**: без него CLI берёт Auto, а Auto в Kaban запрещён. `--approve-mcps` одобряет всё, что CLI видит, поэтому перед стартом демон собирает конфиг MCP сам и сверяет список серверов (9).

Промпт собирает демон: скилл стадии, задача, handoff-резюме, замечания возврата и гейтов, действующие git-разрешения, обязательство закончить `complete_stage` / `return_to_stage` / `request_human` и вызывать `report_progress` хотя бы раз в несколько минут.

Read-only стадия: без `--force`, политика git сужена до чтения; если после run в клоне есть изменения — откат и `waiting_human: invalid_result` при повторе.

Следующая попытка после `gate_failed` и `no_final_call` продолжает работу в том же клоне, в промпт добавляются вывод гейта или напоминание закончить через `complete_stage`. После `crash` и таймаутов клон откатывается (3.3), а `refs/kaban/wip/<run-id>` человек может восстановить из панели деталей.

### 6.2 Окружение launchd
LaunchAgent не получает PATH из shell. Путь к `cursor-agent`, PATH и тулчейны демон берёт из своего конфига (детект при первом запуске через login shell, правится в настройках). Авторизация из-под launchd — **[спайк 1]**, запасной вариант `CURSOR_API_KEY` из Keychain в env процесса.

### 6.3 Коммиты
Агент коммитит в ветку задачи сам; после зелёных гейтов демон делает страховочный коммит `kaban: <stage> <task>`. Сводка Human Review: `git diff --stat base...branch`, коммиты, резюме стадий.

### 6.4 Классификатор сбоев и сверка модели
- **Сверка модели.** Фактическая модель приходит только в первом событии `system/init` и только отображаемым именем. Демон сравнивает его с `model_catalog.name` для запрошенного id. Совпало — дальше. Имя известно и не совпало — `model_substituted` (3.3): run убивается до первого вызова инструмента, клон чистый, в ленту и на карточку идут запрошенная модель (имя и id), ответившая модель, `fallbackModel` (если был в ошибке), время, номер run, ссылка на лог. Имени нет в каталоге или оно неоднозначно — серая строка `model_unconfirmed` в ленте, run продолжается. Подмену посреди сессии поток не показывает; что видно при `fallbackModel` и `--resume` — **[спайк 1]**.
- **Лимитные ошибки.** `usage limit` / `spendLimitHit` → `usage_exhausted` на пул модели run, а если пул не определить — на весь Мак (`unknown`) (дата сброса — `billingCycleEnd` из квоты или парсинг `chatMessage`); `resource_exhausted` / «not available in the slow pool» → флаг модели `unavailable`; прочий rate-limit → `rate_limited` с cooldown. Run, получивший ошибку, попытку не списывает.
- **Молчаливый выход** (ни одного вызова инструмента, ни одного изменённого файла) → `retry_wait: silent_exit` и пробный запуск: та же модель, короткий промпт, разбор вывода и debug-лога. Проба одна на модель за раз и не чаще раза в 10 минут. Нашлась лимитная причина — флаг по правилу выше (`usage_exhausted` на пул, если пул известен, иначе на Мак); проба прошла чисто — это обычный сбой, попытка списывается задним числом.
- Сигналы и фикстуры для фейкового драйвера — **[спайк 1]**.

## 7. Квоты

Бюджета в долларах в MVP нет, но usage (если CLI его отдаёт, **[спайк 1]**) пишется в `run` для будущих метрик.
- **Реактивная схема (всегда).** Лимитные ошибки разбирает классификатор (6.4): `rate_limited` с cooldown 15 → 30 → 60 мин, `usage_exhausted` на пул (на весь Мак только при `unknown`), флаг модели `unavailable` только для её стадий. Текущие runs доигрывают; run, получивший ошибку, попытку не списывает.
- **Проактивная проверка (опция, M4).** Выключена по умолчанию, включается с явным согласием, помечена «неофициально». Демон читает токен **только для чтения**: собственный токен `cursor-agent`, если **[спайк 1]** его найдёт (тогда проценты гарантированно того же аккаунта, IDE не нужна), иначе `cursorAuth/accessToken` из `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (read-only). Токен живёт только в памяти, не пишется на диск, в лог и БД, демон его никогда не обновляет (иначе IDE разлогинится): протух — данных нет. Запрос один — `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, без редиректов. Cm = `planUsage.autoPercentUsed`, Om = `planUsage.apiPercentUsed`, сброс = `billingCycleEnd` (строка с миллисекундами эпохи). Нет процента или `"enabled": false` — «нет данных», а не 0%. Начало цикла — `billingCycleStart`, если ответ его отдаёт (**[спайк 1]**), иначе календарно тот же день месяцем раньше. Сессия браузера и `usage-summary` не используются. Если чтение `state.vscdb` из-под LaunchAgent вызывает системный запрос, базу читает приложение и передаёт демону проценты (**[спайк 1]**).
- **Опрос.** Интервал из настроек (1, 5, 15, 30 мин или своё) и после каждого завершённого run; планировщик берёт кэш. Перед **каждым** стартом run (взятие из Backlog, переход в следующую стадию, ретрай) нужна свежесть не старше 60 с, иначе внеочередной запрос. Данные старше 30 мин — остаток неизвестен, работает только реактивная схема.
- **Порог.** Отдельно для Cm и Om, по умолчанию 10%. Пул run определяется по `model_catalog` / `model_pool_rule` для явной модели стадии. Старт разрешён, если `остаток − запас > порог`, где `запас = runs в этом пуле × средний расход run` (из `quota_sample`; пока истории нет — 2% на run). Ниже порога — задача остаётся в `queued: quota_cm | quota_om` и не держит очередь. Om ниже порога при живом Cm останавливает только стадии на моделях из Om; автоподмены модели нет — модель меняет только человек и только на явную.
- Ручные паузы — из менюбара и тулбара.

## 8. Git и изоляция

### 8.1 Рабочая копия задачи
- `git clone --local` основного репозитория в `~/Library/Application Support/Kaban/Workspaces/<project>/<task>`: объекты хардлинками, свои refs, `config`, hooks. `remote.origin.pushurl = kaban-no-push`.
- Ветка `kaban/<task>-<slug>` от актуального `main` при входе в первую agent-стадию; один клон проходит все стадии задачи. Режим `fresh-readonly` даёт стадии отдельный свежий клон ветки.
- Прогрев: `warm_paths` из основной копии через `cp -c` до старта агента, затем `on_create`. Для Xcode — свой `-derivedDataPath` внутри клона. Выигрыш по типам кэшей замеряем в **[спайк 6]**.
- Порты: на задачу диапазон `KABAN_PORT_BASE`.
- Клон удаляется после `done`/`cancelled` с задержкой.
- Пересечение файлов: при входе в agent-стадию и после каждого коммита стадии сравниваем `git diff --name-only main...branch` с другими задачами в работе и ставим бейдж обеим. Слияние не блокирует.

### 8.2 Границы защиты
1. **Правила `cursor-agent`** для shell-команд (**[спайк 1]**). Сюда попадают **только жёсткие инварианты** (`push`, `remote`, `config`, запись в `.kaban/` и т. п.). Настраиваемые запреты сюда не кладём: иначе CLI отклонит команду раньше обёртки, и «разрешить один раз» не сработает.
2. **Обёртка `git`** (`KabanGitShim`) первой в PATH: сверяет команду с итоговой политикой стадии через `/git/check` (8.3), даёт понятный отказ. Обходится через `/usr/bin/git` — это фильтр и источник удобных отказов, а не граница.
3. **Seatbelt** (`sandbox-exec`, тот же механизм, что у песочниц Codex CLI и Claude Code на macOS): запись только в клон задачи, temp и список кэшей и служебных каталогов `cursor-agent`; запрещены запись в основной репозиторий, `~/.gitconfig`, `Application Support/Kaban`, чтение `~/.ssh` и `~/Library/Application Support/Cursor/User/globalStorage/` (токен IDE). Сеть для команд агента — по allowlist хостов; loopback — только порт MCP-сервера доски. Минимальный профиль и эти запреты — **[спайк 6]**.
4. **Проверка результата демоном** после каждого run — настоящая граница: refs, теги и `config` основного репозитория совпадают со снимком; в ветке задачи нет изменений `.kaban/` относительно `main`; коммиты только поверх базы задачи. Перед проверкой демон возвращает `.cursor/mcp.json` клона к версии из `main` (подмена конфига MCP — наша, 9) и не учитывает её в diff. Нарушение → откат refs из снимка, `waiting_human: incident`, событие-инцидент с уведомлением.

Git hooks защитой не считаем (`--no-verify`, `-c core.hooksPath=`).

Политика из `.kaban/` настраивает слой 2 (и пресеты в UI). Жёсткие инварианты не снимает ни один пресет: агент не двигает `main` и чужие ветки, не пушит, не пишет в `.kaban/`; слияние в `main` делает только демон.

### 8.3 Отказ и «разрешить один раз»
1. Обёртка берёт `KABAN_RUN_TOKEN` из env и перед каждой командой делает `POST /git/check { argv, cwd }` на loopback-сервер.
2. Демон нормализует argv (подкоманда, флаги, без путей файлов, где это не меняет смысл) и проверяет: жёсткие инварианты → итоговая политика стадии → `git_grant` (задача, нормализованный argv, `uses_left = 1`, живёт до конца задачи). Разрешение списывается в той же транзакции, что и проверка.
3. Отказ: обёртка **сразу** завершается с ненулевым кодом и текстом «команда запрещена политикой проекта, запрос отправлен человеку; продолжай без неё или жди разрешения». Ничего не ждёт, чтобы не сработал stall-таймаут. Демон пишет событие `git_denied` (тихая запись в ленте), счётчик отказов run +1; на 5-м — run останавливается, `waiting_human: git_denials`.
4. Человек нажимает «разрешить один раз» (`allowGitOnce`) — создаётся `git_grant`, событие в журнал.
5. Доставка агенту:
   - run жив — демон прикладывает уведомление «`git rebase …` разрешена один раз, можно повторить» к ответу на **следующий вызов любого инструмента доски** (MCP), поэтому скилл обязывает агента периодически вызывать `report_progress`; повтор команды пройдёт `/git/check` и спишет разрешение;
   - run уже закончился — разрешение попадает во вход `git_grants` следующего run этой стадии и в промпт.
6. «Добавить в политику» — обычная правка `.kaban/` с автокоммитом, действует с новых runs по снимку версии.

Если на `/git/check` нет ответа (демон перезапускается) — обёртка отказывает (fail closed).

### 8.4 Слияние
Строго последовательная очередь на проект: `fetch` ветки из клона → rebase на `main` во временном клоне слияния → гейты → ff-merge.
- Конфликт rebase → abort, задача в первую agent-стадию с приоритетом, списком конфликтующих файлов и расширением `rebase` в политике, затем снова все стадии и **всегда** Human Review (решение Артёма). Счётчик `conflict` +1, лимит 2 → `waiting_human: conflict_limit`. Rebase чистый, но гейты красные — тот же путь.
- `main` выбран в рабочей копии человека → `git merge --ff-only` в ней; если правки человека пересекаются с входящими файлами → `blocked: main_dirty`, после очистки повтор автоматически. Если выбрана другая ветка — двигаем ref `main` напрямую.

## 9. MCP-сервер доски

- Streamable HTTP на `127.0.0.1:<порт>`, `Authorization: Bearer <run-token>`; токен определяет проект, задачу, стадию и run и отзывается по завершении run.
- Инструменты: `get_task_context`, `report_progress(text)`, `complete_stage(summary, artifacts?)`, `return_to_stage(target, issues[])`, `request_human(question)`. Все через автомат, нелегальный переход возвращает понятную ошибку, повтор в рамках run идемпотентен. Ответ любого инструмента может нести `notices[]` (git-разрешения, ответ человека на вопрос, если сессия продолжена).
- **Белый список.** По умолчанию агенту доступен только сервер доски. MCP проекта (из `.cursor/mcp.json`) и личные MCP Артёма (из `~/.cursor/mcp.json`) включаются явным списком в настройках проекта (`project_mcp_allow`).
- **Конфиг собирает демон на каждый run:** сервер доски с `${env:KABAN_RUN_TOKEN}` (токен только в env процесса, в файлах его нет) плюс серверы, выбранные в стадии и включённые в белом списке. Если сервер выбран в стадии, но выключен в белом списке, его нет в конфиге, а валидатор выдаёт предупреждение, не ошибку: пайплайн остаётся валидным. Этим файлом подменяется `.cursor/mcp.json` в клоне (если файла не было — он добавляется в `info/exclude`), а перед проверкой результата файл возвращается к версии из `main`. Личный `~/.cursor/mcp.json` агенту не виден за счёт отдельного `HOME` run, если CLI при этом не теряет логин; иначе — другой способ подключения без записи в репозиторий (**[спайк 1]**, **[спайк 2]**).
- **Fail closed.** Перед стартом демон в том же окружении проверяет, какие серверы видит CLI (`cursor-agent mcp list`, **[спайк 1]**). Хоть один сервер вне собранного конфига — run не стартует, проект получает `unavailable: mcp_unexpected` с именем сервера.
- Run завершился без финального вызова → `retry_wait: no_final_call`.

## 10. Восстановление после сбоев

При старте демона:
1. Runs в `running`: проверить pid и время старта процесса; живые — убить process group, run → `killed: daemon_restart`, задача → `retry_wait: daemon_restart` без списания попытки.
2. Задачи в `gating` — перезапустить гейты.
3. Клоны с незакоммиченными изменениями после убитого run — сохранить состояние в `refs/kaban/wip/<run-id>` и откатить к последнему коммиту стадии (только внутри клона).
4. Проверка результата (8.2, слой 4) для всех проектов.
5. События в журнал, запуск планировщика.

## 11. Несколько проектов

- Проект попадает на доску перетаскиванием из списка проектов (дубль для VoiceOver — «Показать на доске» в контекстном меню), убирается крестиком в шапке дорожки после кнопки настроек. Скрытие — только вид: проект не удаляется и не паузится, задачи идут. Набор и порядок дорожек хранит приложение, новый проект сразу появляется на доске.
- Основной вид — дорожки проектов со своими столбцами; компактный вид по `kind` с чипом исходной стадии на карточке; общие столбцы без дорожек — только если `id` стадий у проектов совпадают.
- В компактном виде задача в `waiting_human` любой стадии показывается в столбце «ждёт человека».
- Баннер `max_waiting_human` — в шапке дорожки проекта (лимит на проект), глобальные паузы — над доской.
- MCP и `/git/check` — один сервер на все проекты.
- Маскот — личная настройка в БД, генерируется из стабильного id проекта.

## 12. Human Review и уведомления

Панель: резюме стадий, вывод гейтов, `diffstat`, коммиты, пометка «изменено при разрешении конфликта». Кнопки: «Открыть в Cursor» (`cursor <путь клона>`), «Одобрить», «Вернуть с комментарием» (с выбором стадии), «Отклонить» (с выбором: отменить задачу или в стадию).

Уведомления шлёт приложение-менюбар на `waiting_human` (кроме `review` — по настройке) и с повышенной важностью на инцидент. **[спайк 4]**: можно ли слать их напрямую из агента в бандле.

## 13. Безопасность

- Hardened runtime, Developer ID, без App Sandbox.
- Loopback-сервер только на 127.0.0.1, токен на run, XPC только для нашего подписанного клиента.
- Секреты в Keychain, не в промптах и логах; маскирование известных шаблонов ключей в логах.
- `--force` для unattended-режима осознанно, граница — Seatbelt и проверка результата (8.2). Контейнеры — после MVP.
- MCP только из белого списка, конфиг собирает демон, лишний сервер — fail closed (9).
- Токен квоты (опция, 7) — только чтение, только в памяти, один endpoint.
- **Остаточный риск: токен самого `cursor-agent`.** Профиль Seatbelt действует на CLI и всех его потомков, а CLI должен читать свой токен, поэтому внутри одного профиля команды агента тоже могут его прочитать. Меры: сетевой allowlist для команд агента, правила `cursor-agent`, запрет на `state.vscdb` IDE. Цель **[спайка 6]** — запускать CLI вне песочницы и включать её только для его инструментов; если не выйдет, риск остаётся принятым.

## 14. Спайки до утверждения (на Маке Артёма)

1. `cursor-agent` headless: флаги записи, `--approve-mcps`, `--model`; правила разрешений shell; формат `result` (usage); коды выхода; `session_id` и `--resume` в `-p`; PATH и авторизация из-под launchd. Добавлено в v0.10: реальный вид трёх лимитных случаев (месячная квота, `resource_exhausted`, молчаливый выход) с фикстурами stream-json и stderr; где видна фактическая модель и меняется ли `init` при `fallbackModel` и `--resume`; формат `--list-models`; `cursor-agent mcp list`; отдельный `HOME` без потери логина; где лежит токен CLI; чтение `state.vscdb` из-под LaunchAgent; отдаёт ли `GetCurrentPeriodUsage` поле `billingCycleStart` (иначе календарный запасной вариант, 7).
2. MCP из клона: подхват `.cursor/mcp.json`, подстановка env, вызовы по HTTP; подключение сервера доски без записи в репозиторий и подмена закоммиченного `.cursor/mcp.json` проекта.
3. `SMAppService.agent` + Mach-сервис + `XPCSession` из SwiftUI.
4. Уведомления из агента в бандле.
5. Мини-конвейер: две задачи параллельно, возврат Test → Dev, слияние с намеренным конфликтом, отказ git и «разрешить один раз».
6. Seatbelt-профиль для `cursor-agent` и сборок; запрет чтения `globalStorage` Cursor из-под агента; изоляция токена CLI (CLI вне песочницы, песочница на инструментах); сетевой allowlist; `clone --local`: место, скорость, `fetch`; эффект `warm_paths`.

## 15. Порядок разработки

- **M0** спайки.
- **M1** ядро на Linux: `KabanModel`, `KabanStateMachine`, `KabanStore`, `KabanScheduler` с фейковым драйвером, `kabanctl`.
- **M2** исполнение: `CursorCLIDriver`, `KabanHTTP` (MCP и `/git/check`), обёртка git, клоны, гейты, проверка результата, восстановление.
- **M3** UI: доска, карточка, лог, Human Review, настройки стадии и git, менюбар, уведомления.
- **M4** слияние и квоты: очередь merge, конфликты, классификатор лимитных ошибок, флаги модели, опция проактивной квоты.
- **M5** подпись, нотаризация, релиз.

## 16. Открытые вопросы

- К аналитику: перенести в спеку ссылку на 3.2 вместо своей таблицы статусов; поправить UC-01 (чистая рабочая копия не нужна), UC-09 (run доигрывает, `paused` только ручная), UC-10 (`failed` → `waiting_human: retries_exhausted`), UC-14 (шаблон коммитится при добавлении проекта).
- К дизайнеру: приоритет отображения на карточке, когда одновременно статус, счётчик возвратов, пересечение файлов и непогашенное git-разрешение.

## Журнал изменений

- v0.10.2: набор проектов на доске вместо режимов «один / несколько / все» (5, 11), подписка приложения на все проекты; `billingCycleStart` в спайке 1 (14).
- v0.10.1: `usage_exhausted` по пулам (на весь Мак только `unknown`); `actual` в `model_flag` необязательно; `quotaUpdated` с `billingCycleStart?` и «нет данных» вместо 0%. В §9 конфиг MCP собирается из пересечения выбора стадии и белого списка, а выключенный сервер даёт предупреждение.
- v0.10 (по журналу решений от 3 октября): Auto запрещён, `model` обязательна, моделей по умолчанию нет, стадия без модели делает пайплайн некорректным; некорректная версия в `main` останавливает новые старты вместо работы на последней корректной; `backoff` на одну паузу короче числа попыток (`[30s, 2m]` — ждёт Артёма); попытки на заход в стадию, `max_runs_per_task` и `waiting_human: run_limit`; `refs/kaban/wip/<run-id>` перед откатом; классификатор сбоев, `silent_exit` и пробный запуск; `usage_exhausted`, флаги модели `unavailable` и `substituted`, `model_substituted` и `model_unconfirmed`; проактивная квота Cm/Om (опция), `model_catalog`, `model_pool_rule`, `quota_sample`; белый список MCP, конфиг MCP от демона, `mcp_unexpected`; запрет на `globalStorage` Cursor в Seatbelt и остаточный риск токена CLI; спайки разложены по номерам §14.
- v0.9: таблица `incident`, события `incidentOpened` / `incidentResolved`, `listIncidents`, `openIncidentCount` в снимке; инцидент закрывается командой человека по задаче.
- v0.8: «Замечание агенту» идёт через `answerHuman(taskId, text, requestId?)` из любого `waiting_human`; `keepBranch` в `cancelTask` и `reject` (архив `kaban/archive/<task-id>`); событие `gitGrantDelivered`.
- v0.7: флаги планировщика с причинами одной таблицей (3.2), включая `runner_unavailable` и реактивный путь по ошибке авторизации; `project_missing` и `no_pipeline` перенесены из статусов задачи во флаги проекта; `getTaskDetail` и долговечная лента `task_feed_item`; `scope` в `addDenialToPolicy`; имена событий git-разрешений; `recheck`.

- v0.6: единый набор статусов и причин, `failed` убран; команды Human Review `approve` / `requestChanges` / `reject`; полный список XPC-команд, снимок с `seq`, `commandId`, журнальные и эфемерные события; механизм «разрешить один раз» (8.3); правила CLI только для жёстких инвариантов; `max_waiting_human` на проект; удаление непустой стадии запрещено; запись пайплайна через `updatePipeline` и обработка ручных правок; все упоминания worktree заменены клоном задачи.
- v0.5: прогрев клона (`warm_paths`, `on_create`).
- v0.4: `clone --local`, слои защиты git, политика git, чтение правил из `main:.kaban/`.
- v0.3: несколько проектов, справедливый планировщик.
- v0.2: стадии из конфига.
- v0.1: решения аналитика по WIP и возвратам.
