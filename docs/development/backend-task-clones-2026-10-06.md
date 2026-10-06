# BE-06: клоны задач

Дата: 6 октября 2026. Ветка `codex/be-06-task-clones`, база — `codex/be-05-effect-execution`
(`992a6f3`, [PR #76](https://github.com/imedfan/kaban/pull/76), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). PR этого инкремента открыт поверх #76 и ещё не принят в main.

## Реализовано

`task_clone` v8 хранит план до вызова git. `git clone --local` идёт через `DaemonGit`:
hooks и fsmonitor выключены, push URL клона — `kaban-no-push`, ветка `kaban/<task>-<slug>`
от `main` клона. `fresh-readonly` создаёт второй клон с отдельным git dir.
DerivedData и `.kaban-tmp` создаются внутри клона. Диапазон портов стабильно считается из id
и никуда не bind.

Повтор `prepare` при готовом клоне не создаёт другой каталог. Частичный каталог на зарезервированном
пути удаляется только после проверки и заменяется клоном на том же пути. `currentRunId` и pending
`startAgentRun` не дублируются. HEAD, `refs/heads/main`, porcelain status и `.git/config` пользователя
не меняются.

`cleanupClone` после claim и до receipt архивирует tip в `refs/kaban/archive/<task>`, если
`keepBranch` истинен, и удаляет только записанный путь внутри workspace. Совпадение с копией
пользователя, путь вне workspace и чужой путь отклоняются. Повтор уже подтверждённого эффекта
не удаляет каталог снова. `--clone-pass` не включён по умолчанию и не запускает Cursor.

## Границы

WIP save/restore, process group, Seatbelt и Cursor CLI не входят в инкремент. Архивный ref — единственная
запись в основном репозитории, и только при `keepBranch`. Рабочая копия и `main` не переписываются.

## Проверки

- `TaskCloneTests`: разные refs/config/cwd, нетронутый origin, частичный клон и тот же run после reopen,
  архив по `keepBranch`, отказ удалить origin.
- Два запуска `KabanDaemon --clone-pass` печатают один и тот же `clone ready` / `clone origin-clean`.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 404 tests, 0 failures.
