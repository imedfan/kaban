# BE-13: проверка результата, подозрительные файлы и инциденты

Дата: 6 октября 2026. Ветка `codex/be-13-incidents`, база — `codex/be-12-git-grants`
(`297fb59`, [PR #85](https://github.com/imedfan/kaban/pull/85), открыт поверх `codex/be-10-mcp-isolation` и ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Pull request открывается поверх `codex/be-12-git-grants` и этим коммитом ещё не записан.

## Реализовано

После run `judgeResult` сравнивает основной репозиторий со снимком, снятым в `prepareTaskClone` до записи готовности клона. Снимок — `refs/heads`, `refs/tags` и сырой `.git/config`. `refs/kaban/` в снимок не входит. Первый снимок проекта сохраняется (`ON CONFLICT DO NOTHING`). Порядок: heads → `refs_moved`, tags → `tags_changed`, config → `config_changed`. Откат — `update-ref` / `update-ref -d` и запись сохранённого config. Текущая ветка не удаляется.

Дальше проверяется `.kaban/` task branch: зафиксированный `base...HEAD`, porcelain с untracked и подмена каталога symlink. `.kaban-tmp` в pathspec `.kaban` не входит. Если трёхточечный diff не имеет общего предка, деревья сравниваются напрямую: совпавшее дерево — не правка `.kaban`. Затем `merge-base --is-ancestor`: чужой предок — `foreign_base`. Откат ветки — снять symlink, `reset --hard` на записанную базу и удалить только porcelain `??` под `.kaban`.

Подозрительные файлы сканируются после зелёных гейтов и до следующей стадии. Паттерны и `max_file_mb` берутся из пайплайна, `allow` исключает совпадения. Стандарт смотрит зафиксированный `base...HEAD`. Strict добавляет `git diff HEAD` и `ls-files --others`. `.cursor/mcp.json` перед сканом возвращается к blob `main` и из набора исключается. Blob зафиксированного файла — `rev-parse HEAD:path`, blob рабочего дерева — `hash-object -w` (без `-w` новый blob не лежит в базе и `cat-file -s` не отдаёт размер). `isText` у зафиксированного diff берётся из `git diff --numstat` (`-`/`-` — не текст). У untracked текст — отсутствие байта NUL. Удалённые пути пропускаются. Попадание — `waiting_human: suspicious_files` и `suspiciousFilesFound`. Попытка не списывается.

Приоритет: инцидент, затем подозрительный файл, затем грязь read-only, иначе чисто. Обычная грязь стадии без read-only остаётся чистой. Пустой клон — чистый результат, не read-only.

`incidentOpened`/`incidentResolved` и `projectUpdated` пишутся в той же записи `apply`, с одним `commandId`. `ProjectSummary.openIncidentCount` — число нерешённых строк. Снимок суммирует эти поля. `projectRemoved` убирает проект из суммы. Клиентская проекция не увеличивает и не уменьшает счётчик по `incidentOpened`/`incidentResolved`; порядок событий внутри транзакции не требуется. Инцидент закрывается в той же записи, что и человеческая команда, уводящая задачу из `waiting_human: incident`.

`acceptSuspiciousFiles` принимает ровно показанный набор path+blob. Иной набор — `stale_suspicious_files`, ничего не пишется, ожидание остаётся. Принятые пары лежат в `task_accepted_file` и не срабатывают снова. Новый blob того же пути срабатывает. После принятия задача снова проходит проверку результата и, если она чистая, выполняет отложенный переход. Нового run и новой попытки нет. `answerHuman` и `requestChanges` набор не принимают. `retryStage`, `moveTask`, `cancelTask` и `reject` в стадию принимают его. `requestChanges` в dev допустим: у dev `permissions: write`.

`DaemonService.support` помечает `.acceptSuspiciousFiles` и `.listIncidents` как `.supported`. `restoreWIP`, `checkEnvironment`, `getCursorEnvironment`, `configureCursor`, `listProjectMcpServers` и `setProjectMcpAllowlist` остаются `.unsupported`. Карточка несёт `suspiciousFiles` только в `waiting_human: suspicious_files`. У `TaskDetail` нет поля инцидентов: список даёт `listIncidents`.

## Границы

Откат git выполняется в `judgeResult` до `commitEffectResult`. Если запись базы после отката не пройдёт, повтор может увидеть уже чистое дерево. Exactly-once внешнего git это не обещает. Merge, rebase и fast-forward остаются BE-17. Production `updatePipeline` по-прежнему не поддержан. Автокоммит YAML не делается. Прямой `/usr/bin/git` shim обходит; граница записи — профиль BE-10. Логи run остаются BE-16.

## Проверки

- `IncidentTests` на свежей базе: паттерны, размер, allow, исключение `mcp.json` и незакоммиченных файлов в standard; strict видит untracked и symlink и не берёт обычный `form.txt`. Попытка не растёт. После `discardJournal` detail и карточка всё ещё несут набор, пока задача ждёт.
- Тот же набор в обратном порядке принимается и продолжает стадию без нового run. Чужой blob — `stale_suspicious_files`. Новый blob `.env` срабатывает снова, прежний `api/.env.local` нет.
- `answerHuman` и `requestChanges` принятых строк не пишут. `retryStage`, `moveTask` в backlog, `cancelTask` и `reject` в dev пишут. После обрезки журнала принятые строки остаются, непринятые — нет.
- Untracked, зафиксированная правка и symlink `.kaban/` откатываются в `kaban_dir_changed`. Следующий tick run не начинает.
- Новая ветка, tag, дописка config и осиротевший commit дают `refs_moved`, `tags_changed`, `config_changed` и `foreign_base`. Откат снимает след. `incidentOpened` и `projectUpdated` делят `commandId`. Снимок равен сумме по проектам. После `discardJournal` инцидент и счётчик живы. `cancelTask` закрывает инцидент тем же `commandId`, что и `projectUpdated` с нулём. `removeProject` обнуляет сумму снимка.
- Два `--stage-pass` печатают один stderr: `stage once gate dev passed` и `stage once result dev suspicious`.
- macOS: `KABAN_SCENARIOS=Scenarios/M1 swift test --filter IncidentTests` — 6 tests, 0 failures. Полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 477 tests, 0 failures (Transport 23, Protocol 64, Kit 180, DaemonCore 144, Board 66).
