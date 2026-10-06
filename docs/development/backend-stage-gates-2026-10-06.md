# BE-11: гейты, hooks и передача стадии

Дата: 6 октября 2026. Ветка `codex/be-11-stage-gates`, база — `codex/be-10-mcp-isolation`
(`a4c6bc5`, [PR #83](https://github.com/imedfan/kaban/pull/83), влит в `codex/be-09-mcp-server` и ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Pull request — [#84](https://github.com/imedfan/kaban/pull/84), влит в `codex/be-10-mcp-isolation` и ещё не принят в main.

## Реализовано

`complete_stage` по-прежнему только входит в `gating` и ставит `.runGates`. Дальше `--stage-pass` и `runStagePass` исполняют цепочку: hook выхода предыдущей стадии, один commit, hook входа, команды гейта, проверку результата, откат read-only. Обычный запуск демона эту цепочку не крутит и Cursor не вызывает. Проход стоит до `recover`, как `--mcp-pass`.

Команда гейта и hook идут через `/bin/sh -c` в каталоге клона, с таймаутом wall стадии. Зависший процесс получает статус 124 и убивается вместе с группой. Окружение — PATH, HOME, TMPDIR, USER, LOGNAME, LANG и `LC_*`, плюс `agent.env` стадии. `GIT_*` и имена с KEY, TOKEN, SECRET или PASSWORD отбрасываются. `KABAN_RUN_TOKEN` в эту среду не копируется. Вывод ограничен 8192 байтами.

Повтор того же effect не запускает команду второй раз: строка `stage_work` и маркер `Kaban-Effect:` в сообщении commit. Новый заход той же стадии получает новый effect и гоняет гейт заново. Commit собирается через `write-tree` / `commit-tree`, поэтому `pre-commit` репозитория не исполняется. Чистое дерево commit не создаёт.

Красный гейт агента оставляет ту же стадию и тот же клон, пишет `gate_output` и списывает попытку (`gate_failed`). Следующий старт после backoff идёт с `continueInClone` и этим текстом. Красная отдельная gate-стадия в том же месте не повторяется: `failReturn` ведёт в `on_fail.stage` или в ближайшую предыдущую writable agent-стадию, счётчик захода обнуляется. Test → Dev кладёт конкретные issues в промпт следующей роли. Лимиты пары и `bounce_limit_total` остаются в автомате. Исчерпание `max_runs_per_task` на списанной неудаче даёт `waiting_human: run_limit`.

Strict пишет один commit с текстом `complete_stage.summary` (пустой текст — `kaban: <stage> <task>`). Standard и Free пишут страховочный `kaban: <stage> <task>`, только если дерево грязное. Summary, diffstat, список commit и issues сохраняются в деталях задачи.

## Границы

Проверка результата в этом инкременте смотрит только грязь read-only стадии по фактам git. Грязное дерево обычной стадии для этой проверки считается чистым; страховочный commit при этом всё равно один, если есть изменения. Подозрительные файлы, инциденты, `listIncidents` и `acceptSuspiciousFiles` остаются BE-13. `/git/check` и grants — BE-12. Rebase и fast-forward merge — BE-17. Повтор внешнего процесса в общем случае не обещает exactly-once: второй commit и второй hook этого прохода не создаются за счёт маркера и строки работы.

## Проверки

- `StageCommandTests`: вывод команды сохраняется; `/bin/sleep 30` при таймауте 0.3 с заканчивается быстрее 2 с со статусом 124. Второй `commitMarked` с тем же маркером возвращает тот же sha, `pre-commit` не создаёт файл, новая грязь с тем же маркером не даёт второй commit.
- `StageGateTests`: зелёный exit без final call не входит в `gating` и при `max_runs_per_task: 1` ждёт человека с `run_limit`. Красный гейт агента повторяет стадию и клон. Красная gate-стадия возвращает в `dev` с нулём попыток. Возврат несёт конкретную issue, новый заход обнуляет attempts, второй возврат при `bounce_limit_total: 1` ждёт человека. Replay печатает те же строки, hook-файл один (`enterexit`), commit стадии один. Пайплайн доходит до `waiting_human: review`. Strict коммитит summary один раз. Первая грязь read-only откатывается в `retry_wait(readonly_violation)`, вторая за тот же заход — `invalid_result`. Два запуска `KabanDaemon --stage-pass` печатают один и тот же stderr.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 460 tests, 0 failures (Transport 23, Protocol 64, Kit 178, DaemonCore 129, Board 66). Два `--stage-pass` печатают один stderr.
