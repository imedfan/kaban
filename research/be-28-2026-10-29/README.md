# BE-28: бесплатная проба профиля

Проба запускает только `--version`, `status --format json` и `mcp list`.
`-p` и запросов к модели нет. HOME/TMPDIR отдельные, Keychains — вариант BE-22/24.
В выводе только версия, exit codes, признак авторизации и наличие сервера `kaban`;
учётные данные и содержимое status/MCP в Git не сохраняются. Временные файлы удаляются.

Из корня репозитория на macOS:

```sh
swiftc Sources/KabanKit/MCP/SeatbeltProfile.swift Sources/KabanKit/Agent/CursorRunHome.swift \
  research/be-28-2026-10-29/main.swift -o /tmp/kaban-be28-free
/tmp/kaban-be28-free /absolute/path/to/cursor-agent
```

Предварительная проба 28 октября прошла на CLI `2026.09.23-86fc751`:
exit 0 для всех трёх команд, `isAuthenticated=true`, `kaban` найден, stderr пуст.
Финальная проба 29 октября на source `5e6a584` повторила результат;
[очищенные факты](free-facts.json), [отчёт](../../docs/development/backend-be-28-2026-10-29.md).
Это не подтверждение платного `-p`, коммита настоящим агентом, гейтов,
полной трассировки записи, installed helper или изоляции токена CLI.
