# BE-08: управление процессами

Дата: 6 октября 2026. Ветка `codex/be-08-process-control`, база — `codex/be-06-task-clones`
(`20b6da3`, [PR #77](https://github.com/imedfan/kaban/pull/77), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Реализация — `961028d`.
[PR #78](https://github.com/imedfan/kaban/pull/78) открыт поверх #77 и ещё не принят в main.

## Реализовано

`agent_process` v9 хранит pid, pgid, время рождения, start id, stdout/stderr, stall и wall.
`--process-pass` с `--runner` делает `posix_spawn` с `POSIX_SPAWN_SETPGROUP`: pgid равен pid и больше 1.
Факт `started` пишется после spawn и не является receipt: `startAgentRun` не завершает стадию.
Без `--runner` pending start остаётся pending. Флаг не включён в обычный старт демона и не запускает Cursor.

Exit 0 с выводом или грязным клоном переводит задачу в `retry_wait: no_final_call` и не двигает стадию.
Тихий exit 0 без вывода и без изменений файлов остаётся `.running`; метка `silent_deferred` не вызывает переход BE-15 и не списывает попытку.
Exit после паузы или `complete_stage` помечается `ignored_late` и не меняет задачу.
Ненулевой код — `crash`. Stall и wall сравниваются с часами вызывающего, без ожидания; wall проверяется раньше stall.
Пауза, перенос назад и отмена шлют SIGKILL только записанной группе. Потомок, не сменивший группу, умирает вместе с ней.
Повторный stop уже остановленной группы не сигналит. Чужой pgid отклоняется до сигнала.
`daemon_restart`, `rate_limit`, `usage_exhausted`, `runner_auth` и `model_substituted` не списывают попытку и `runsSinceHuman`.
Три `crash` подряд дают паузы 30 с и 2 мин, затем `waiting_human: retries_exhausted`.

Crash и timeout пишут `refs/kaban/wip/<run>` внутри клона (`git commit-tree`) и откатывают worktree к прежнему HEAD.
`no_final_call` и `gate_failed` этот ref не создают и оставляют файл в клоне. Путь, совпадающий с копией пользователя, не получает git-запись.

## Границы

BE-07 не реализован: runner в проверках — `/bin/sh`, `/bin/sleep` и `/usr/bin/python3`, не Cursor CLI.
Нет argv Cursor, `sessionId`, разбора stream и `runner_unavailable` по отсутствию бинарника.
Классификация тихого выхода, probe и списание после probe остаются BE-15.
Повторное использование pid и «второй агент после reopen» остаются BE-18; сверка времени рождения только не даёт убить чужой процесс.
Восстановление WIP человеком остаётся BE-18/19. Обрыв между spawn и INSERT может оставить процесс без строки и при следующем проходе стартовать ещё один: это не exactly-once.
Обычный XPC-старт процесс не порождает. Проход процесса не встроен в scheduler, чтобы старые kill/rollback effects не подтверждались сами.

## Проверки

- `ProcessGroupTests`: классификация exit 0, отказ убить чужую группу без ожидания, потомок в той же группе умирает от SIGKILL.
- `ProcessControlTests`: `no_final_call` не двигает стадию; тихий exit остаётся `.running`; поздний exit остаётся `gating`;
  пауза, перенос, отмена, restart, rate limit, usage, auth и substitution не списывают попытку;
  три crash дают 30 с, 2 мин и `retries_exhausted`; stall и wall возвращают проход быстрее 5 с, пока `/bin/sleep 30` ещё жив;
  пауза одной задачи убивает её потомка и не трогает вторую группу; повторный kill идемпотентен;
  `no_final_call` и `gate_failed` сохраняют файл клона, crash откатывает его и пишет WIP ref;
  подмена пути клона на origin отклоняется, HEAD и status пользователя не меняются.
- Два запуска `KabanDaemon --process-pass` печатают один и тот же `process group task-run started` / `process exit task-run no_final_call` и не дописывают счётчик запусков.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 415 tests, 0 failures (Transport 23, Protocol 64, Kit 162, DaemonCore 100, Board 66).
