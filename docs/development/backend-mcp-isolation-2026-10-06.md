# BE-10: проверка MCP и изоляция записи

Дата: 6 октября 2026. Ветка `codex/be-10-mcp-isolation`, база — `codex/be-09-mcp-server`
(`7c9f9b7`, [PR #82](https://github.com/imedfan/kaban/pull/82), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md). Pull request — [#83](https://github.com/imedfan/kaban/pull/83), влит в `codex/be-09-mcp-server` и ещё не принят в main.

## Реализовано

Preflight собирает конфиг run из сервера доски и серверов стадии, которые есть в allowlist. Остальные выбранные серверы дают предупреждение `mcp_not_allowlisted` и в конфиг не попадают. Токен в файле только как `${env:KABAN_RUN_TOKEN}`. `--approve-mcps` не передаётся: нечитаемый, пустой или ненулевой `mcp list`, лишнее имя и столкновение endpoint блокируют `start` с `mcp_unexpected`. Конфиг при этом не становится копией чужого файла.

Подменённый `.cursor/mcp.json` восстанавливается из записанных байт при recovery и в `--mcp-isolation-pass`. Если файла не было, он удаляется, а строка `.git/info/exclude` снимается. Symlink не преследуется. После восстановления `git diff` пустой.

Профиль Seatbelt запрещает запись в `.git` и `.kaban` клона и вне клона. Проба гоняет `/usr/bin/git config` и прямую запись, не shim. Тот же `git config` без профиля меняет файл.

## Границы

Это не гарантия изоляции. Профиль разрешает общее чтение и не прячет токен CLI. По архитектуре §13 CLI остаётся вне профиля, а песочница относится к инструментам; токен процесса CLI по-прежнему может быть прочитан самим CLI. Запись в `.git` этим профилем запрещена целиком, поэтому commit, fetch и rebase им не обещаны. Сеть в этой пробе не измерялась.

`listProjectMcpServers` и `setProjectMcpAllowlist` остаются `.unsupported`. `/git/check` не сделан. Установленный CLI `2026.09.23-86fc751`: `status` сообщает `Not logged in`, `mcp list` не печатает собранный набор. Отдельный HOME с живой авторизацией не показан. Платный `-p` не запускался. `state.vscdb` не читался.

## Проверки

- `MCPIsolationTests`: предупреждение не включает сервер; чужой и нечитаемый list блокируют; столкновение endpoint не копирует сервер в конфиг; `--approve-mcps` нет ни в конфиге, ни в argv. Подмена tracked-файла исчезает из `git diff`. Новый файл удаляется и не остаётся в status. Symlink не получает запись. `/usr/bin/git config` и прямая запись под профилем не меняют marker, запись в клон разрешена, тот же git без профиля меняет config.
- `MCPIsolationStoreTests`: блок отклоняет следующий `start` и оставляет задачу queued. Чистый list со предупреждением стартует. Recovery возвращает прежние байты. Два запуска `KabanDaemon --mcp-isolation-pass` печатают одну строку `mcp restore a clean`.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 450 tests, 0 failures (Transport 23, Protocol 64, Kit 176, DaemonCore 121, Board 66).
- CLI: `cursor-agent status` → `Not logged in`; `mcp list` не показывает серверы. Пункт про auth, сборку и MCP в реальном профиле не закрыт.
