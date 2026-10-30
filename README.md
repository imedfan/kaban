# Kaban

Локальное macOS-приложение для канбан-пайплайна разработки: задачи проходят
agent-, gate-, human- и merge-стадии с явными моделями, WIP, ретраями и git-политикой.
Kaban — основной проект. Нативная SwiftUI-доска подключена к локальному daemon
через XPC; developer-режим использует private stdio. Ядро содержит SQLite,
production scheduler, Cursor CLI/MCP, git shim, Seatbelt, гейты и recovery.
Полная сквозная приёмка установленного приложения ещё открыта;
[FE-22](docs/development/frontend-fe-22-2026-10-30.md) фиксирует результаты и блокеры.

## Начало работы

- [Текущее состояние](docs/current-state.md) — что реализовано и что осталось в ветках.
- [Инструкции агента](AGENTS.md) — короткий вход и маршруты чтения.
- [Рабочие правила](docs/contributing.md) — ветки, проверки, PR и действующая политика.
- [Сборка и запуск](docs/getting-started.md) — окружение и проверенные команды.
- [Документация](docs/README.md) — рабочие источники и результаты переноса из Drive.

## Код

| Где | Назначение |
|---|---|
| Sources/KabanProtocol/ | Codable DTO, команды, snapshot/details и события |
| Sources/KabanKit/ | YAML/pipeline, git-policy и чистый автомат |
| Sources/KabanDaemonCore/ | GRDB/SQLite, журнал/effects, fake driver, scheduler и recovery |
| Sources/KabanTransport/, Sources/KabanDaemon/, Sources/kabanctl/ | Клиент транспорта, daemon host и CLI; XPC macOS 26 и development stdio |
| Sources/KabanBoardCore/ | KabanClient, проекция, BoardSet, pending commands и presentation; только Protocol |
| App/KabanApp/ и Kaban.xcodeproj | Нативные SwiftUI views и BoardStore; Protocol/BoardCore |
| Tests/ и Scenarios/M1/ | Unit/integration suites и сценарии |
| design/ | Закреплённые оригиналы макетов, токенов, бренда и маскотов |
| spikes/ | Отдельные runtime-эксперименты |

## Проверка

Из корня, Swift 6.1+ (на Linux нужны SQLite headers, python3 и curl для проверок):

```sh
python3 tools/check-project-context.py
swift build
KABAN_SCENARIOS=Scenarios/M1 swift test
```

Приложение требует macOS 26+ и полный Xcode с соответствующим SDK.
SwiftPM-пакет имеет минимум macOS 15. `swift test` не проверяет вид SwiftUI-окна.
Unsigned app build и запуск описаны в [App/README.md](App/README.md).
Повторяемая автоматическая матрица FE-22 с настоящим WindowGroup, Debug/Release
подписями и отдельным статусом live-приёмки — [tools/README.md](tools/README.md#приёмка-fe-22).

## Требования

- [Архитектура](docs/architecture-v0.md), [поведение MVP](docs/kaban-mvp-features-usecases.md), [журнал решений](docs/decisions-log.md).
- [Frontend plan](docs/frontend-plan-v0.md) с отдельными документами экранов; [backend plan](docs/backend-plan-v0.md).
- [Дизайн и версии](design/README.md), [критерии приёмки](docs/acceptance-criteria-v0.md).

Документация ведётся в Git; актуальные источники Drive перенесены в docs/.
Drive остаётся историческим источником. Материалы
[архива](docs/archive/README.md) и [team2](docs/team2/README.md)
сохраняют происхождение решений и не ограничивают основную разработку.
