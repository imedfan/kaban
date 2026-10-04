# Начало работы с Kaban

Срез: 4 октября 2026, база `origin/main` — `1d647ea` (#8, protocol-v2 для BoardCore). В корне сейчас SwiftPM-пакет с тремя библиотеками и их тестами. Собрать пакет можно на Linux и macOS; приложение, daemon и GRDB ещё не подключены к Package.swift.

Свежие источники продукта: [архитектура v0.11.22, §2](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view), [спека v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view), [план фронта v0.5.36](https://drive.google.com/file/d/1LXl5tv4Wjw6CNfNbs8vezjLSxgkZWtc_/view), [AC v0.1](https://drive.google.com/file/d/14z297h5-6AOABSw-53kHCtnntKW_NxAv/view). Копии docs/* в репозитории могут быть старее этих снимков. Правила team2 — [чек-лист](https://docs.google.com/document/d/1oszVHm1jwJ6HvuQKCnr9Z-6PTICnfJ6_t3csqTWcpk0/edit).

## Получить код и проверить окружение

Нужны git и Swift 6.0 или новее. Проверенный в CI Linux toolchain — контейнер `swift:6.0`; наличие Swift в PATH проверяется командой `swift --version`. Для библиотек на macOS Package.swift задаёт минимум macOS 15.0. Приложение и фронтенд-спайки рассчитаны на macOS 26/Xcode 26 по исходным документам; сборка SwiftPM не проверяет Liquid Glass или XPC-приложение.

```bash
git clone https://github.com/imedfan/kaban.git
cd kaban
swift --version
git --version
swift build
KABAN_SCENARIOS=Scenarios/M1 swift test
```

Ожидается `Build complete!` и итог тестов без failures. Команды выполнять из корня клона, где лежит Package.swift. Kaban не нужно регистрировать в launchd, входить в Cursor или задавать модель, чтобы собрать и проверить эти библиотеки.

`KABAN_SCENARIOS` указывает на каталог JSON **Scenarios/M1**, не Scenarios. Его использует `Tests/KabanProtocolTests/ScenarioDecodeCheck.swift`: без переменной этот тест пропускается; при несуществующей/пустой папке падает. Это проверка декодирования протокола сценариев, не интеграционный прогон реального агента.

Для отдельной проверки сценариев:

```bash
KABAN_SCENARIOS=Scenarios/M1 swift test --filter ScenarioDecodeCheck
```

## Linux: воспроизвести CI

В [.github/workflows/ci.yml](../.github/workflows/ci.yml) обязательная job «Linux (Swift 6)» выполняет `swift build`, затем `swift test` с `KABAN_SCENARIOS=Scenarios/M1` в `swift:6.0`. Установленный локально Swift 6 может отличаться от CI; для совпадения окружения можно использовать существующий Docker:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.0 swift build
docker run --rm -e KABAN_SCENARIOS=Scenarios/M1 -v "$PWD":/src -w /src swift:6.0 swift test
```

Docker-команды здесь не запускались. Образы/движок нужно иметь доступными на машине. Если чередуете Linux и macOS в одном checkout, используйте разные scratch-каталоги, чтобы не смешивать артефакты разных платформ:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.0 swift build --scratch-path .build-linux
docker run --rm -e KABAN_SCENARIOS=Scenarios/M1 -v "$PWD":/src -w /src swift:6.0 swift test --scratch-path .build-linux
```

`.build-linux/` — локальные результаты, в PR их не добавлять. Исходники и CI этим не изменяются.

## macOS: библиотеки и отдельные кэши

Обычные команды те же: `swift build`, `KABAN_SCENARIOS=Scenarios/M1 swift test`. macOS CI сейчас optional (`continue-on-error: true`), поэтому проверяйте итог самой job: зелёный workflow не означает, что macOS job прошла.

Для проверки с новым scratch/cache, без удаления существующей `.build`:

```bash
kaban_check_dir=$(mktemp -d /tmp/kaban-check.XXXXXX)
mkdir -p "$kaban_check_dir/cache" "$kaban_check_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$kaban_check_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$kaban_check_dir/module-cache"
swift build --scratch-path "$kaban_check_dir/build" --cache-path "$kaban_check_dir/cache"
KABAN_SCENARIOS=Scenarios/M1 swift test --scratch-path "$kaban_check_dir/build" --cache-path "$kaban_check_dir/cache"
```

Сохраните итог и путь результатов в отчёте; удаление scratch-каталога не требуется для успешного прогона. В ограниченной среде Codex manifest/build могут быть запрещены sandbox-политикой. `--disable-sandbox` отключает sandbox SwiftPM, но не внешнюю sandbox среды. На этом хосте существующие git-тесты при внешнем sandbox получали предупреждение `confstr()` в выводе git; для проверки их запустили вне этого ограничения. Не менять ожидаемые значения production-тестов из-за такого сообщения среды.

## Карта фактических модулей

| Папка / библиотека | Назначение | Зависимости сейчас | Тесты |
|---|---|---|---|
| [KabanProtocol](../Sources/KabanProtocol/) | Codable-команды/ответы/снимки/события, стадии, статусы и причины, validationCodes, AgentEvent | Foundation | [KabanProtocolTests](../Tests/KabanProtocolTests/), golden fixtures и ScenarioDecodeCheck |
| [KabanKit](../Sources/KabanKit/) | Пайплайн/YAML, validation, git-policy, state machine и её эффекты; текущие Git/SuspiciousFiles helpers | KabanProtocol | [KabanKitTests](../Tests/KabanKitTests/) |
| [KabanBoardCore](../Sources/KabanBoardCore/) | Проекция snapshot/events, BoardSet, правила drop, тексты причин, MascotKit | Только KabanProtocol | [KabanBoardCoreTests](../Tests/KabanBoardCoreTests/) |

[Архитектура §2](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view) показывает целевую систему шире текущего пакета. `KabanDaemonCore`, `KabanAgentDrivers`, `KabanHTTP`, отдельный `KabanGit`, `KabanGitShim`, `KabanDaemon` и `KabanApp` — планируемые модули; в Package.swift на указанной базе их нет. GRDB не является подключённой зависимостью. SwiftUI-клиент по архитектуре импортирует Protocol/BoardCore; валидность пайплайна и state machine остаются за демоном/Kit.

## Спайки из PR #3 и #4

Спайки не входят в корневой SwiftPM-пакет и не запускаются `swift test`. [PR #3](https://github.com/imedfan/kaban/pull/3) — frontend FS-1…9; [PR #4](https://github.com/imedfan/kaban/pull/4) — backend 1/2/6. Номер PR и номер спайка различаются.

| Где | Что запускает | Основные prerequisites / результат |
|---|---|---|
| [spikes/frontend/](../spikes/frontend/README.md) | KabanSpikes, отдельная заглушка агента; FS-1 связан с backend spike 3 (XPC/SMAppService), FS-6 — с backend spike 4 (уведомления) | Полный Xcode 26/SDK 26, macOS 26, XcodeGen, Apple Development и DEVELOPMENT_TEAM; сырые результаты в results/, вердикт по шаблону RESULTS.md |
| [spikes/backend/](../spikes/backend/README.md) | cursor-agent headless (1), MCP (2), Seatbelt и клоны (6) | macOS 26/Apple Silicon, Terminal.app, CLT, Python 3.9+, git, установленный и авторизованный cursor-agent, явная модель; архив out/kaban-spikes-*.zip |

### Frontend: подготовка и команды будущего прогона

Проверки prerequisites не регистрируют агента:

```bash
xcodebuild -version
xcrun swift --version
command -v xcodegen
```

Полную последовательность и подпись взять из [README спайков](../spikes/frontend/README.md). Когда prerequisites настроены владельцем, сборка:

```bash
cd spikes/frontend
DEVELOPMENT_TEAM=XXXXXXXXXX ./run.sh
```

`XXXXXXXXXX` заменить на собственный Team ID. Скрипт генерирует проект и Signing.xcconfig, проверяет YAML fixture, вызывает XcodeGen/xcodebuild и подпись. `./run.sh --generate-only` генерирует файлы; `./run.sh --open` открывает собранное приложение. FS-1/FS-7 требуют стабильного пути приложения и регистрации в UI; FS-6 проверяет уведомления/Developer ID отдельно. Эти действия описаны в README и здесь **не выполнялись**. Если запускали регистрацию в своей тестовой сессии, закончить штатной кнопкой «Снять регистрацию» по исходной инструкции.

### Backend: подготовка и команда будущего прогона

```bash
cd spikes/backend
KABAN_SPIKE_MODEL='<явный-id-из-каталога>' ./run-all.sh
```

Это длительный реальный эксперимент, не smoke-test библиотеки: примерно 20 запусков модели по оценке README, сеть/квота Cursor, временный LaunchAgent и probes Seatbelt. Проверить текущие CLI-флаги и login в своей среде по README; team2 не подтверждает реальную совместимость CLI результатами SwiftPM. При необходимости `KABAN_SPIKE_ONLY="1 6"` выбирает часть; модель должна быть явной. Не класть токены, личные конфиги и необработанные логи в PR.

Скрипты backend spike **3/4** отдельно в этом каталоге не поставлены: там только 1/2/6; frontend FS-1/FS-6 дают материал для вопросов XPC и уведомлений. Не выдавать работу заглушки за проверенный production-демон.

## Проверка этого документа

На базе `1d647ea` использованы свежие scratch/build, SwiftPM cache и module cache в `/tmp`; существующая `.build` не использовалась. Хост: macOS **27.0.1**, Xcode **27.0**, Apple Swift **6.4**, arm64. Это другой toolchain, чем целевые macOS/Xcode **26** спайков; сборка библиотек не подтверждает работу спайков на 26 или 27.

- `swift build` с отдельными путями кэша и `--disable-sandbox`: `Build complete! (5.75 с)`, exit 0.
- Полный `KABAN_SCENARIOS=Scenarios/M1 swift test`: exit 0 вне внешнего sandbox; Protocol **32**, Kit **107**, BoardCore **46** XCTest-тестов, всего **185**, 0 failures. ScenarioDecodeCheck прошёл; последняя suite завершилась 4 октября 2026 в 14:16:18 по времени хоста.
- Ограниченный sandbox-прогон тестов не был зелёным: `DaemonGitTests` получил `confstr()` warning в stdout git. Это ограничение среды; исходники не исправлялись.
- Linux подтверждён существующими CI job: [PR #29, Linux (Swift 6), SUCCESS, 4 октября 2026](https://github.com/imedfan/kaban/actions/runs/37188285203/job/111394877261). Это проверка той ветки (baseline + F2), не чистой Linux-машины локально и не текущего документа. Для PR T6 требуется отдельный CI после публикации.
- Реальный cursor-agent, frontend xcodebuild, LaunchAgent/SMAppService registration, уведомления, подпись и системные настройки не запускались.

Критерий T6 «чистая машина» подтверждён здесь только частично: новое состояние build/cache на имеющемся Mac, а не заново установленная ОС. Сырые build/test логи сохранены для PR-отчёта; README и существующие документы не менялись. Если команда падает, зафиксировать toolchain, команду, код выхода и текст ошибки; для расхождений занятых зон использовать issue по правилам team2.
