# Сборка и запуск Kaban

Команды выполняются из корня checkout. Состояние функций — [current-state](current-state.md),
рабочие правила — [contributing](contributing.md). Исходный build guide сохранён в [архиве](archive/2026-10-04/getting-started.md).

## Окружение

SwiftPM требует Swift 6.1+; библиотеки собираются на Linux и macOS 15+.
GRDB 7.11.1 уже подключён. Для Linux нужны SQLite development headers.
SwiftUI-приложение требует macOS 26+ и полный Xcode с SDK macOS 26 или новее.
Доступный хост аудита: Xcode 27 / Apple Swift 6.4; это не проверка runtime на macOS 26.

```sh
git status --short
git branch --show-current
swift --version
python3 tools/check-project-context.py
swift build
KABAN_SCENARIOS=Scenarios/M1 swift test
```

`KABAN_SCENARIOS` обязателен: без него часть сценарных suites пропускается.
Узкий прогон выбирает существующее имя Suite из Tests/:

```sh
KABAN_SCENARIOS=Scenarios/M1 swift test --filter Team2TakeoverFrontendFoundationTests
```

Team2 в именах старых тестов — историческое имя, не ограничение рабочей роли.

## Linux

CI использует контейнер swift:6.1, устанавливает libsqlite3-dev и выполняет
swift build/test. При уже установленном Docker эквивалентная проверка:

```sh
docker run --rm -v "$PWD":/src -w /src swift:6.1 bash -lc 'apt-get update && apt-get install -y libsqlite3-dev && swift build --scratch-path .build-linux && KABAN_SCENARIOS=Scenarios/M1 swift test --scratch-path .build-linux'
```

Контейнерная проверка не является запуском macOS-приложения.

## Daemon и CLI

Backend transport собирается корневым `swift build`. `kabanctl --help` описывает
snapshot/send/subscribe/watch. Mach service предназначен для подписанного
launchd host и требует same-Team signature; упаковка/регистрация ещё не выполнены.
Для development smoke используй private stdio и временную БД:

```sh
swift build
kaban_bin_dir=$(swift build --show-bin-path)
"$kaban_bin_dir/kabanctl" --stdio-daemon "$kaban_bin_dir/KabanDaemon" --database /tmp/kaban-demo.sqlite snapshot
python3 tools/smoke-daemon-transport.py --bin-dir "$kaban_bin_dir"
```

Команда `send` принимает JSON CommandEnvelope с исходным commandId и сохраняет
его при retry. Stdio запускает один child daemon для данного CLI; существующую БД
параллельный второй daemon не открывает. Следует использовать development БД,
поскольку startup выполняет recovery. Границы — [daemon transport](development/backend-daemon-transport-2026-10-05.md).

## macOS-приложение

```sh
xcodebuild -version
xcodebuild -project Kaban.xcodeproj -scheme Kaban \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/kaban-context-app \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
open /tmp/kaban-context-app/Build/Products/Debug/Kaban.app
```

Или открой Kaban.xcodeproj, выбери shared scheme Kaban и Run.
Подпись не требуется для этой unsigned build. Текущий main использует MockKabanClient,
не устанавливает daemon и не запускает Cursor. Проверяй основное окно и пользовательские
действия отдельно от чистой BoardProjection. Подробности — [App](../App/README.md).

В CI macOS job optional. Для готовности App проверь её фактический conclusion
и шаг xcodebuild; успешная Linux suite не доказывает визуальное соответствие.

## Изоляция кэшей и ошибки среды

Для отдельной SwiftPM-проверки без удаления существующей .build:

```sh
kaban_check_dir=$(mktemp -d /tmp/kaban-check.XXXXXX)
mkdir -p "$kaban_check_dir/cache" "$kaban_check_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$kaban_check_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$kaban_check_dir/module-cache"
KABAN_SCENARIOS=Scenarios/M1 swift test --scratch-path "$kaban_check_dir/build" --cache-path "$kaban_check_dir/cache"
```

Внешняя sandbox может запрещать manifest/cache/system вызовы. Запиши ошибку и
проверяй допустимым способом; не меняй production assertions из-за предупреждения
среды. --disable-sandbox меняет только sandbox SwiftPM, не права внешней среды.

## Спайки

[Frontend](../spikes/frontend/README.md) и [backend](../spikes/backend/README.md)
живут вне корневого пакета и имеют собственные prerequisites. Реальные CLI-спайки
расходуют квоту и могут регистрировать агента; они не являются обычной проверкой документов.
