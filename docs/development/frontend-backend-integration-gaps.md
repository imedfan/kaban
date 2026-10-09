# Frontend MVP: незавершённые контракты бэкенда

Проверено 7 октября 2026 на main `ff04e05` и рабочих FE-03/04 ветках.
Требования [FE-01–22](frontend-mvp-tasks.md) сохраняются полностью. Этот файл
фиксирует расхождение предположения «BE-01–20 завершены» и фактического кода;
UI не заменяет отсутствующие producers локальными догадками.

Дополнение FE-11 проверено 8 октября 2026 на базе main `6ae93e0` и коде `7464467`;
исходный срез FE-03/04 выше остаётся историей своих проверок.

| Для frontend | Фактический контракт | Необходимое завершение |
| --- | --- | --- |
| FE-03: путь Cursor, готовность окружения | `Sources/KabanDaemonCore/DaemonService.swift`: checkEnvironment/getCursorEnvironment/configureCursor объявлены unsupported. `StoreCommands.swift` не реализует эти wire commands. | Typed reads и durable configureCursor с replay, journal cursorEnvironmentChanged; path из чтения после restart. Факты version/auth/git/sandbox получают реальные producers, без запуска модели. |
| FE-03: discovery и recheck runner | `Sources/KabanDaemonCore/StoreRunner.swift` проверяет сохранённый executable; без path refreshRunnerIfDue ничего не запускает. Путь задаётся аргументом daemon --cursor-agent, не App. recheck runner supported. | Подключить сохранённый environment к launch-agent/startup, discovery и настоящему probe. Не выдавать отсутствие полного EnvironmentReport за успешную готовность. |
| FE-03: штатная служба | [BE-20](backend-launch-agent-2026-10-06.md) зафиксировал отказ sandboxed App установить unsandboxed helper. Упаковка/peer identity и developer stdio присутствуют. | Принятая конфигурация безопасности и подписи; register/approval return/handshake/restart/unregister/reboot на штатном bundle. Выбор файла App не доказывает разрешение helper. |
| FE-04: выбор произвольной базовой ветки | `Command.addProject` не содержит baseBranch; `LocalGitRepository.init` требует локальную main, `pipeline()` читает main, template на другой checkout возвращает template_checkout_required. listBranches — только read. | Завершить согласованный wire/backend контракт выбора ветки по UC-01. UI показывает серверную baseBranch и список; не переключает repo от имени пользователя и не придумывает параметр команды. |
| FE-04: папка после restart | App хранит security-scoped bookmarks и даёт повторный выбор, но штатная App/helper установка не принята из-за BE-20. Developer private DB reopen проходит. | Проверить NSOpenPanel grant, сохранённый bookmark, права именно helper, утрату grant и исправление на принятом signed bundle после restart. Entitlement и stdio smoke не закрывают эту проверку. |
| FE-04: редактирование обнаруженных гейтов | detectGates — предложения команд из committed descriptors; отдельной wire-команды записи гейтов нет. | Продолжить flow через единый FE-13 pipeline draft/validate/apply. Это frontend dependency, не право запустить найденный script или молча заменить pipeline. |

| FE-05: подтверждённые процессы и время исполнения | TaskCard имеет running/updatedAt, RunSummary — DB status/startedAt; отдельного подтверждения external spawn/актуальной liveness и wall deadline нет. | Дать producer/wire факты по runId и process lifecycle. Сейчас UI показывает резервирование / полученный current-run progress и неизвестность числа живых процессов, без счёта gating или выдуманного elapsed. |
| FE-05: причины лимитов и прогресс гейтов | PipelineSummary не передаёт bounce_limit_total/структурированный exhausted rule; TaskCard counters не доказывают выбранный rule. DTO также не имеет queuePosition и gate-step progress. | Передать точный rule/title/qualifier и числа из источника. UI использует известные onConflict/runLimit; неизвестный общий limit, очередь и gate N/M не угадываются. |

Frontend FE-03 реализует состояния этих отказов и путь действий по capabilities.
Протокольные fixtures проверяют rendering/correlation, но не закрывают live
приёмку перечисленных контрактов. Остальные известные ограничения production
Cursor/MCP, quota и policy описаны в [current-state](../current-state.md);
они уточняются в соответствующей FE-задаче.

## FE-06: первоначальный приоритет при создании

F3/UC-02 включает приоритет в создание. Command.createTask и StoreCommands
принимают projectId/title/body; новая TaskCard получает default priority=0.
setPriority поддержан и durable, но влияет на следующий выбор scheduler.
После создания задача уже может быть выбрана до отдельной смены приоритета.

В FE-06 приоритет меняется явным отдельным действием после создания.
UI не обещает атомарное создание с приоритетом и не останавливает проект
ради скрытого обхода. Для полного UC-02 нужен согласованный контракт
initial priority в createTask с legacy decoding/default=0 и atomic card/journal
в той же transaction. Это расхождение не закрыто native smoke или зелёным CI.

## FE-08: полный текст при превышении wire-размера

StoreProjection.getTaskDetail проверяет весь TaskDetail через ensureWireFit и
возвращает detail_too_large без обрезки сохранённых полей. Command предлагает
getRunHistory и transport readLog, но не отдельное/постраничное чтение body,
feed и artifact.text. Поэтому новый клиент без cache не может получить эти
материалы из слишком большого ответа. Path материала — metadata, не разрешение
читать произвольный файл.

FE-08 различает этот отказ и пустой результат, сохраняет последний полный текст,
показывает bytes/limit при наличии и даёт отдельные history/log reads.
Для полного доступа к неполученным body/artifacts нужен согласованный bounded
read-контракт с task/run ownership, offset/version и legacy совместимостью.
Это ограничение источника данных; frontend не восстанавливает материалы из
retained journal и не подменяет текст fixtures.


## FE-09: историческая попытка и заход в стадию

Проверено по RunSummary и StoreDetail.swift на базе FE-08 0c579a9.
StoreDetail присваивает RunSummary.number = d.runs.count + 1: это порядковый
номер запуска задачи. Wire DTO не содержит номер попытки внутри исторического
захода и идентификатор stage_entry; таблица stage_entry остаётся внутренней.
Повторный вход в ту же стадию нельзя отличить по одному stageId.
UI поэтому показывает «запуск №», текущий TaskCard.attempt/maxAttempts и
явную неизвестность исторической попытки. Нужны backward-compatible optional
поля attempt/stageEntry в history; legacy fixtures и новые producers должны
проверяться отдельно. Требование FE-09 сохраняется, локальная реконструкция
по неполному журналу его не заменяет.

## FE-11: материалы ревью

`Sources/KabanKit/Git/TaskClone.swift` формирует diffstat через `git diff --stat`.
Знаки +/− масштабируются; пути могут быть сокращены. Producer в StoreStages
передаёт этот текст в TaskArtifact. FE-11 распознаёт формат, показывает переданный
total changes и количество строк списка, но точные per-file additions/deletions
оставляет неизвестными; исходник доступен целиком. Для точной таблицы нужен
структурированный backward-compatible artifact либо полный `--numstat` с путями.
Renderer поддерживает exact numstat, но текущий producer его не отправляет.

TaskDetail/RunSummary/TaskArtifact не передают стоимость и token usage. Merge
conflict виден через bounceByReason и issue materials; отдельный список правок
при разрешении конфликта не поступает. UI показывает факт предыдущего конфликта
и текущий результат, не реконструирует такой diff из неполного журнала.
Нужны реальные producers и optional wire-поля; требования UC-07/08 сохраняются.

Найденный пробел durable review comment исправлен в этом FE-11: requestChanges
сохраняет redacted review_comment в TaskDetail.feed в одной транзакции с state,
journal и outbox. Replay не дублирует запись; invalid_state не пишет её.
Wire test и [настоящий daemon restart/retention](frontend-fe-11-2026-10-08.md)
подтверждают сохранность. Новая запись не является humanAnswered и не принимает вопрос.

## FE-12: очередь и материалы слияния

На коде `5760bea` исправлены merge FIFO независимо от priority, передача
optional mergeQueueSequence из task_admission и атомарные durable материалы
merge_conflict/merge_gate_output/merge_result. Последний содержит фактические
baseCommit, commit и refs/heads/main из merge_intent после confirmed merged,
включая startup recovery. [Приёмка](frontend-fe-12-2026-10-08.md) проверила
настоящие Git, daemon, native UI и retention; прошлое отсутствие этих фактов
не является текущим ограничением FE-12.

Остаются отдельные wire-фазы rebase/gates/fast-forward: TaskCard.gating не
передаёт phase и внешний progress. Нет списка пересекающихся с dirty main
путей в blocked/event/detail. TaskCard.overlapsWith есть в контракте, но
production producer вычисления пересечений в DaemonCore отсутствует; UI
работает с переданными IDs и не вычисляет их самостоятельно. Связанные
недавние задачи для конкретного конфликта также не передаются отдельным
материалом. Отдельный diff исправления конфликта, точные numstat и usage/cost
из FE-11 остаются открыты. Это технические зависимости, не недоработки дизайнера.

## FE-16: живая повторная проверка MCP

В рабочей `codex/fe-16-project-mcp` подключены wire-команды каталога и allowlist,
авторитетные snapshot/journal facts, validation context и безопасная диагностика.
Каталог читает конфиги в production store, разрешения сохраняются отдельно по
проекту. Это закрывает прежний `.unsupported` этих двух команд в BE-10.

Обычный production loop по-прежнему не получает свежий `cursor-agent mcp list`
для `recheck(project)`. Ранее pipeline refresh мог снять `.mcpUnexpected` без
такого факта; FE-16 сохраняет блок до успешного `applyMCPPreflight` и публикует его
имя/тип через `projectUpdated`. Нужен настоящий producer с run/stage ownership,
собранным конфигом, изоляцией личного профиля и authenticated CLI. Критерий FE-16
про устранение unexpected через настройки/перепроверку остаётся открытым;
успех UI, unit preflight seam или private stdio не заменяет живой CLI результат.

## FE-17: доставка grant в следующий Cursor-промпт

Проверено на базе FE-16 `a20a48d` и реализации FE-17. В Sources нет producer
`GitGrantDelivered.via = .nextPrompt`. `StoreMCP.environmentForAgentRun` передаёт
run token; RunSpec не содержит входа `git_grants`, а StoreProcesses не формирует
Cursor-промпт. Это расходится с архитектурой §8.3 и UC-17: новый запуск должен
узнать о разовом разрешении в промпте, если живой агент не получил его через MCP.

FE-17 сохраняет созданный grant для того же task/stage. Настоящий board-tool
вызов доставляет notice и записывает `.mcpResponse`; `/git/check` отдельно
фиксирует consumption. UI различает эти факты и не создаёт `.nextPrompt` или
delivered timestamp локально. Нужен production producer prompt material с
привязкой task/stage/run, durable delivery и проверкой restart/replay. Native
QA запускал private production daemon и реальные MCP отказы, без Cursor CLI;
он не закрывает этот producer или полный M1.
