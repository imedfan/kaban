# Frontend MVP: незавершённые контракты бэкенда

Проверено 7 октября 2026 на main `ff04e05` и рабочей FE-03 ветке.
Требования [FE-01–22](frontend-mvp-tasks.md) сохраняются полностью. Этот файл
фиксирует расхождение предположения «BE-01–20 завершены» и фактического кода;
UI не заменяет отсутствующие producers локальными догадками.

| Для frontend | Фактический контракт | Необходимое завершение |
| --- | --- | --- |
| FE-03: путь Cursor, готовность окружения | `Sources/KabanDaemonCore/DaemonService.swift`: checkEnvironment/getCursorEnvironment/configureCursor объявлены unsupported. `StoreCommands.swift` не реализует эти wire commands. | Typed reads и durable configureCursor с replay, journal cursorEnvironmentChanged; path из чтения после restart. Факты version/auth/git/sandbox получают реальные producers, без запуска модели. |
| FE-03: discovery и recheck runner | `Sources/KabanDaemonCore/StoreRunner.swift` проверяет сохранённый executable; без path refreshRunnerIfDue ничего не запускает. Путь задаётся аргументом daemon --cursor-agent, не App. recheck runner supported. | Подключить сохранённый environment к launch-agent/startup, discovery и настоящему probe. Не выдавать отсутствие полного EnvironmentReport за успешную готовность. |
| FE-03: штатная служба | [BE-20](backend-launch-agent-2026-10-06.md) зафиксировал отказ sandboxed App установить unsandboxed helper. Упаковка/peer identity и developer stdio присутствуют. | Принятая конфигурация безопасности и подписи; register/approval return/handshake/restart/unregister/reboot на штатном bundle. Выбор файла App не доказывает разрешение helper. |

Frontend FE-03 реализует состояния этих отказов и путь действий по capabilities.
Протокольные fixtures проверяют rendering/correlation, но не закрывают live
приёмку перечисленных контрактов. Остальные известные ограничения production
Cursor/MCP, quota и policy описаны в [current-state](../current-state.md);
они уточняются в соответствующей FE-задаче.
