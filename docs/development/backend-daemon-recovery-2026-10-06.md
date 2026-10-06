# BE-18: восстановление production-демона

Дата: 6 октября 2026. Ветка `codex/be-18-daemon-recovery`. База реализации —
`614c15e` (BE-17, [PR #88](https://github.com/imedfan/kaban/pull/88), включая исправление CI).
Ветка содержит интеграцию `origin/main` `ea02f0c`; предыдущие BE-06–17 ещё не все в main.

Штатный startup под writer lease вызывает `recoverProduction` до scheduler/XPC.
Ошибка восстановления останавливает startup. Диагностические `--*-pass` сохраняют
свой ограниченный контракт; они не заменяют штатный startup.

Процессы агента и gates/hooks записывают PID, process group и kernel birth identity.
После spawn shell launcher ждёт разрешения, которое появляется только после durable
записи; без него завершается через пять секунд, не исполнив runner. При восстановлении
принадлежащая группа получает SIGKILL; перед rollback проверяется прекращение исполнения.
Несовпадение birth/group означает чужой PID: сигнал не посылается. Migration v20
добавляет stage process records, receipt production recovery и restart revocation токенов.

До нового admission отзываются все старые run-токены, восстанавливается MCP config,
сверяются завершённые facts/leases, clone intents, gates, stage commit markers,
fast-forward main и cleanup. Backup MCP сохраняется до изменения файла. Final MCP,
который успел попасть в SQLite, не превращается в новый агентский запуск. Повтор final
в пределах прежнего host остаётся идемпотентным; токен прежнего host после restart отвергается.

Running run получает killed/daemon_restart и retry_wait без списания attempts/autoRuns.
WIP ref публикуется до reset клона; повтор находит его даже после reset до DB receipt.
Сбой сохранения WIP не сбрасывает несохранённые файлы. Main при WIP rollback не меняется.
Human Review, paused и done не переводятся reducer recovery в новый run.
Повтор завершённого passId возвращает прежний receipt и не останавливает более поздний run.

Проверки: crash до durable process record, после spawn, после final MCP, при gate,
после stage commit и fast-forward до receipt; PID reuse, orphan gate group, WIP после
reset до DB receipt. Проверки окончательного кода: `KABAN_SCENARIOS=Scenarios/M1 swift test` — 500 tests,
0 failures (Transport 23, Protocol 64, Kit 180, DaemonCore 167, Board 66).
`python3 tools/smoke-daemon-transport.py --bin-dir .build/debug` — passed.
`python3 tools/check-project-context.py` и `git diff --check` — passed.
Narrow suites перед финальным review — 45 tests, 0 failures; добавленный затем
recovery receipt replay покрыт полным прогоном.

Настоящий платный Cursor не запускался. Проверки используют локальные shell/sleep/git
процессы и production projects, не deliverFake. Это BE-18; команды restore и runtime
исполнение ручных действий следуют в BE-19, packaging — в BE-20. Полный MVP не заявляется.
