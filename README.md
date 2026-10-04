# Kaban

Локальное macOS-приложение, «канбан-фабрика». Headless гоняет `cursor-agent` по стадиям канбана: Backlog, Dev, Test, AI Review и Human Review. У каждой стадии своя модель и свой skill, есть WIP-лимиты, ретраи и учёт квот Cursor.

Приложение на SwiftUI (macOS 26, Liquid Glass) только рисует доску. Демон `KabanAgent` работает как LaunchAgent и общается с приложением по XPC. Хранилище — GRDB/SQLite (зависимость подключит бэкенд). Ядро на Swift 6 собирается и тестируется на Linux.

## Структура репозитория

```
Package.swift              SwiftPM-пакет (swift-tools-version 6.0)
Sources/
  KabanProtocol/           Codable-типы XPC-контракта (архитектор)
  KabanKit/                ядро демона (бэкенд)
  KabanBoardCore/          проекция доски без SwiftUI (фронтенд)
Tests/                     по одному тестовому таргету на модуль
docs/                      архитектура, спека, планы, журнал решений
spikes/backend/            спайки бэкенда, наполняется на mbp
spikes/frontend/           спайки FS-1…FS-9, прогон на mbp (`spikes/frontend/README.md`)
.github/workflows/ci.yml   сборка и тесты
```

Модули пока пустые: в исходниках только `// TODO`. Типы протокола не объявлены заранее — их добавит архитектор. `KabanBoardCore` зависит от `KabanProtocol` и `KabanKit`. GRDB в пакете нет.

Приложение `Kaban.app`, демон и `kabanctl` в этот каркас не входят: их соберут отдельные PR на macOS. Веха M1 — ядро на Linux (`KabanModel`, автомат, хранилище, планировщик).

## Сборка и тесты

Команды выполняются в корне репозитория. Нужен Swift 6.1 или новее.

### Linux

Официальный тулчейн: [swift.org/install](https://www.swift.org/install/).

```bash
swift build
swift test
```

То же в официальном контейнере Swift 6:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift build
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift test
```

На каждый push и pull request GitHub Actions гоняет `swift build` и `swift test` в контейнере `swift:6.1`.

### macOS

Те же `swift build` и `swift test` в корне. Для ядра достаточно Swift 6; приложение и Liquid Glass рассчитаны на macOS 26. Джоба macOS в CI стоит на `macos-latest` и не блокирует сборку (`continue-on-error`): обязательный сигнал — Linux.

## Документы

- [Архитектура v0.10.2](docs/architecture-v0.md) — модули (§2), протокол (§5), спайки (§14), вехи M1–M5 (§15)
- [Фичи и юзеркейсы v0.7.2](docs/kaban-mvp-features-usecases.md)
- [План бэкенда](docs/backend-plan-v0.md)
- [План фронтенда](docs/frontend-plan-v0.md)
- [Журнал решений](docs/decisions-log.md)
