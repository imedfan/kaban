# BE-17: очередь локального слияния

Дата: 6 октября 2026. Ветка `codex/be-17-local-merge`, база — `codex/be-16-run-logs`
(`d8b3d77`, [PR #87](https://github.com/imedfan/kaban/pull/87), открыт поверх `codex/be-13-incidents` и ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Pull request этой ветки ещё не открыт. Ветка не в main.

## Реализовано

`approve` ставит задачу в очередь стадии merge. Планировщик берёт одну готовую задачу за tick, в порядке `queue_seq`. Пока на проекте другая merge-задача в `gating` или `blocked`, следующий `startMerge` не claim'ится. `blocked` слот WIP не занимает, но флаг `merge_blocked` не пускает второго писателя. WIP стадии merge по-прежнему 1.

`--merge-pass` после `--stage-pass` и до recovery: fetch ветки task clone, rebase на свежий `main` во временном каталоге `merge/<taskId>` под корнем workspace демона, повтор гейтов, затем fast-forward. Пустая команда гейта — exit 0. Cursor этот проход не запускает. Обычный запуск демона merge не делает. `deliverFake` по-прежнему не считает `startMerge` и `fastForwardMerge` успешным слиянием.

Rebase идёт в отдельном локальном клоне. Конфликт смотрит unmerged paths, делает `rebase --abort` и удаляет временный каталог. Пользовательский checkout и task clone при конфликте не сбрасываются. Успешный rebase делает `reset --hard` только внутри task clone. В origin tip попадает через `refs/kaban/incoming/<taskId>`, затем `merge --ff-only`, если HEAD — `main`, иначе только `git update-ref refs/heads/main`. Done записывается после `rev-parse refs/heads/main == tip`.

Конфликт возвращает в первую coding-стадию (`returnReason` `.mergeConflict`) с именами файлов. После исправления задача снова проходит Human Review. Счётчик `count > limit`: в тестовом пайплайне `on_conflict.limit` равен 1, поэтому второй конфликт ждёт `waiting_human: conflict_limit`. Отмена другой задачи, которая ещё queued на merge, истекает grant и чистит клон; её файл на `main` не появляется.

Если `main` checkout грязный и имена index/worktree пересекаются с входящим diff, задача становится `blocked: main_dirty`. Байты, `git diff` и `git diff --cached` не меняются, ref не двигается. Когда пересечение исчезло, следующий проход шлёт `mainCleaned` и продолжает ту же очередь. Если checkout — другая ветка, обновляется только ref `main`.

Если `main` ушёл от записанного base между rebase и update, пишется `mainMoved` и фаза возвращается в rebase. Чужой commit не затирается. Повторный проход перебазирует задачу на новый head и fast-forward'ит так, что ручной commit остаётся предком.

`prepareFastForward` не claim'ит эффект и не пишет receipt. Git выполняется, затем факт. Если `main` уже равен tip, второй вызов и recovery пишут receipt без второго `update-ref`. Это сверка по git-фактам, не exactly-once внешнего git.

Снимок защиты при `merged` перезаписывается в той же записи, что и переход. Перед rebase `main`-only сдвиг снимка принимается, чтобы повторный dev после конфликта не откатил чужой commit на `main` как `refs_moved`. Проверка результата стадии merge не откатывает сдвиг только `refs/heads/main`. Другие heads, tags и config по-прежнему инцидент.

Намерение rebase лежит в `merge_intent` (миграция `merge_intent_v19`): `base_sha` и `tip_sha` на задачу.

## Границы

Повторный `--merge-pass` печатает те же строки и не добавляет commit, если `main` уже на tip. Файл JSONL и внешний git транзакцией SQLite не откатываются. Значки пересечения файлов из UC-08 не делаются. Расширение git-policy на возврате из конфликта не делается. Автокоммит `.kaban/pipeline.yaml` не делается. `restoreWIP`, среда Cursor и allowlist MCP по-прежнему не поддержаны.

## Проверки

- Две одобренные задачи: один tick ставит в gating только более раннюю. Проход вливает только её файл. Вторая остаётся queued, её файла на `main` нет. Следующие tick и проход вливают вторую; первый tip остаётся предком `main`.
- После записи намерения и до fast-forward на origin коммитится другой файл. `forwardOneMerge` не кладёт файл задачи и не удаляет ручной commit. Следующий проход вливает оба; ручной commit — предок.
- Index и unstaged правка пересекающегося файла сохраняют байты, оба diff и SHA `main`. Задача — `blocked: main_dirty`. Второй одобренный merge остаётся queued и после ещё одного tick. `reset --hard` и следующий проход вливают первую задачу; файл второй по-прежнему отсутствует.
- Crash: claim `fastForwardMerge`, `prepareFastForward` двигает `main`, повторный `prepareFastForward` не добавляет commit. `recoverEffectExecution` без предварительного `commitEffectResult` пишет один receipt. Следующий `runMergePass` SHA и число commit не меняет.
- Конфликт `shared.txt` возвращает в dev с `.mergeConflict` и prompt. Второй проход через review снова конфликтует и ждёт `conflict_limit`. `main` остаётся на расходящемся тексте. Отмена ожидающей задачи отменяет её до записи её файла.
- Два запуска `KabanDaemon --merge-pass` печатают один и тот же stderr, в нём есть `merge <task> ff <tip>`. На `main` два commit: начальный и commit задачи.
- macOS: `KABAN_SCENARIOS=Scenarios/M1 swift test --filter MergeQueueTests` — 6 tests, 0 failures. Полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 490 tests, 0 failures (Transport 23, Protocol 64, Kit 180, DaemonCore 157, Board 66).
