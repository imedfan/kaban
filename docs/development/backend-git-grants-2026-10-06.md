# BE-12: git-обёртка и разовые разрешения

Дата: 6 октября 2026. Ветка `codex/be-12-git-grants`, база — `codex/be-10-mcp-isolation`
(`c882bec`, [PR #84](https://github.com/imedfan/kaban/pull/84), влит в эту ветку и ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Pull request ещё не открыт.

## Реализовано

`POST /git/check` живёт на том же loopback-сервере, что и `POST /mcp`: только `127.0.0.1`, без новой библиотеки. Обычный запуск демона сервер не держит. Тело — `argv` и `cwd`. Ответ всегда `200` с `allow`, `message` и `rule`. Нет ответа, чужой токен и остановленный run — отказ. `cwd` решение не меняет.

`KabanGitShim` — скрипт в PATH. Он спрашивает демон и вызывает git только если тело содержит `"allow":true`. Порт по умолчанию `127.0.0.1:9`: нет демона — ненулевой выход и git не запускается. Настраиваемые запреты в скрипт и в cursor-agent rules не попадают. В rules остаются только жёсткие имена: `push`, `remote`, `config`, `tag`, `update-ref`, `symbolic-ref`, `filter-branch`.

Нормализация снимает ведущий `git`. Ведущие `-c`, `-C`, `--git-dir`, `--work-tree`, `--exec-path` становятся командой `config`. Разрешение сравнивает нормализованный argv целиком: `rebase` не покрывает `rebase feature`, и наоборот. Условный `when: return_reason` остаётся в `conditional` и проверяется сервером по `returnReason` задачи. В безусловный `allowed` он не сливается.

Жёсткий инвариант, запись в `.kaban/` и `notes`/`fetch`/`worktree` на `main` отказывают даже при совпавшем grant и grant не тратят. Пятый отказ того же run в той же записи останавливает run: `waiting_human: git_denials`, попытка не списывается, run убит и `countsTowardLimits = false`.

`allowGitOnce` создаёт один grant на точный argv отказа, задачу и текущую стадию. Повтор того же отказа новый grant не пишет и argv не расширяет. Жёсткий инвариант возвращает `git_hard_invariant`. Доставка notice помечает только `GitGrantDelivered`. Следующий `/git/check` ставит consumption в той же SQLite-записи. `revokeGitGrant` помечает отзыв. После `done` и `cancel` автомат уже ставит `expireGitGrants`; store в той же записи `apply` помечает grant истёкшим и argv оставляет. Неизвестная команда сохраняет исходный argv. `GitGrantExpiryReason` по-прежнему не принимает неизвестную строку.

`addDenialToPolicy` пишет строку в `git_policy_extra`. Её видит run, у которого `startedAt` не раньше `created_at`. Текущий run её не видит, и уже выданный grant этого run один раз срабатывает. Запрет сильнее неиспользованного grant на следующем run.

## Границы

Автокоммит `.kaban/pipeline.yaml` не делается. Production `updatePipeline` по-прежнему отвечает, что применение пайплайна требует lifecycle проекта. Shim обходится прямым `/usr/bin/git`; граница записи — профиль BE-10, а не этот скрипт. Повтор внешнего git не обещает exactly-once: одноразовая трата grant относится к этой проверке внутри одной записи. Подозрительные файлы, инциденты и `acceptSuspiciousFiles` остаются BE-13. Rebase и fast-forward merge остаются BE-17.

## Проверки

- `GitCheckTests`: `-C`/`-c`/`--git-dir` сводятся к `config`; `status` в `.kaban` не блокируется; `rebase` и `rebase feature` — разные команды. Cursor rules и текст shim не содержат `commit` и `rebase`.
- `GitGrantTests`: grant тратится один раз и не расширяет argv. Повтор `allowGitOnce` оставляет один grant. `push`, `-C` и запись `.kaban/` не разрешаются; подсаженный push-grant не тратится. `fetch origin main` — `foreign_refs`. `commit` на strict разрешён только после `return_reason == returned` и в `allowed` не появляется. Доставка не ставит consumption; неизвестный `frobnicate` сохраняет argv; `cancel` истекает grant с `task_cancelled`. Пятый отказ останавливает run без списания попытки. Дополнительный запрет не трогает текущий run и закрывает следующий. `done` истекает grant с `task_done`. Shim без демона и при отказе не запускает git; `status` запускает. Пустой и чужой токен — отказ. Два `--stage-pass` печатают один stderr.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 471 tests, 0 failures (Transport 23, Protocol 64, Kit 180, DaemonCore 138, Board 66). Два `--stage-pass` печатают один stderr.
