# Инструменты проверки Kaban

## Приёмка FE-22

После сборки SwiftPM и ad-hoc Debug/Release:

```sh
python3 tools/check-frontend-acceptance.py \
  --app /tmp/kaban-fe22-app/Build/Products/Debug/Kaban.app \
  --release-app /tmp/kaban-fe22-app/Build/Products/Release/Kaban.app \
  --bin-dir "$(swift build --show-bin-path)" \
  --output /tmp/kaban-fe22-evidence --core-tests
```

`--output` должен быть новым каталогом. Без него создаётся `/tmp/kaban-fe22-*`.
Команды сборки и installed-сценарий — в [отчёте FE-22](../docs/development/frontend-fe-22-2026-10-30.md).
Нужны macOS с активной GUI-сессией и разрешённый запуск App. Во время проверки
не переключайте фокус: строгие keyboard smokes требуют настоящего key window.
Каждый запуск оставляет `summary.json`, отдельные logs, JSON и PNG. Итог
`automated_passed_live_unverified` подтверждает только перечисленные автоматические
шаги. Ошибка/таймаут/отсутствующий или частичный report делают шаг красным;
следующие проверки сохраняются независимо. Контракт результата проверяет
`python3 tools/test-frontend-acceptance.py` (без GUI и Swift).

Проверяются подписи/состав обеих конфигураций, transport/shim, основные нативные
actions в обеих темах, restart BoardSet, minimum/long/empty/error/grouped/Reduce
Motion окна, большой TextKit2 лог и private-daemon настройки Cursor/pipeline/models.
`--core-tests` добавляет полный `KABAN_SCENARIOS=Scenarios/M1 swift test`;
без него поле `environment.coreTests` явно сообщает `not_run`.

QA профили `--board-load-smoke <report> --qa-load-profile 5x50|10x500` проверяют
точные размеры доски, 90 событий из mock через BoardSession, девять настоящих
menu shortcuts, поиск и переключение compact в настоящем WindowGroup. Три
последовательных пакета идут с целевой частотой до 30 Гц и backpressure по
применению. JSON содержит каждую задержку до проекции (включая polling 1 мс),
heartbeat и process peak RSS в байтах. Это один процесс на профиль/тему, не
FPS/drag benchmark; память включает старт App. Значения не являются новым gate.

Скрипт не устанавливает/регистрирует helper, не меняет пользовательскую БД,
не запрашивает системные permissions и не запускает платный Cursor.
CLI в private проверках синтетический. Installed XPC, обновление bundle, reboot,
доставка уведомлений, VoiceOver, physical input, Reduce Transparency/Increase
Contrast и четыре живых запуска остаются отдельными строками матрицы.
HEAD и diff hash в summary описывают checkout во время проверки; для prebuilt
bundle дополнительно сохранены SHA-256 executable. Они сами по себе не доказывают
происхождение сборки — команды/исходный SHA фиксируются в отчёте.

## Рабочий контекст и дизайн

```sh
python3 tools/check-project-context.py
```

Python 3.9+, только standard library. Проверяет локальные ссылки рабочих
документов, бюджет корневого AGENTS.md и SHA-256/размеры всех закреплённых
оригиналов design/. Для PNG проверяет исходные размеры; лишний файл без
manifest и изменение оригинала вызывают ошибку. Проверяет также полные исходные
документы Drive по SHA-256 и существование их рабочих путей в docs/.
Рабочие требования можно обновлять; неизменными остаются снимки импорта в архиве.
Проверка также выполняется в отдельной CI job. Она не заменяет визуальную
приёмку настоящего окна App.

## YAML и сценарии

Python 3.9+, без SwiftPM и изменений CI. YAML smoke использует
[PyYAML SafeLoader](https://pyyaml.org/wiki/PyYAMLDocumentation), dependency
зафиксирована в requirements.txt. Системный Python менять не требуется:

```sh
python3 -m venv /tmp/kaban-tools-venv
/tmp/kaban-tools-venv/bin/python -m pip install -r tools/requirements.txt
/tmp/kaban-tools-venv/bin/python tools/lint-examples.py
python3 tools/scenarios-report.py
```

Запускайте из корня checkout; default пути вычисляются относительно scripts,
поэтому сами Python команды также работают из другого current directory.
examples/pipelines уже находятся в репозитории. Для проверки другого checkout
передайте directory первым аргументом.
Отсутствующий/пустой каталог вызывает ошибку, не green no-op.

lint-examples проверяет YAML синтаксис, mapping root, version/stages/id/kind,
positive agent.model. invalid/ намеренно пропускает семантические ограничения.
Не проверяет graph, ranges, preset policy или существование модели/skills;
`<model-id>` остаётся шаблоном. Проверки KabanKit и smoke — разные результаты.

scenarios-report проверяет JSON/steps/id, дубликаты ключей/id, считает шаги,
сообщает final newline/trailing spaces/2-space формат. Format notices не падают
по умолчанию; `--strict-format` делает их ошибкой. Никогда не переписывает файлы.
Чтение JSON не доказывает исполнимость всех acceptance expectations.

Пример выполненного вывода 2026-10-04, baseline 1d647ea + T7:

```text
YAML smoke: 11 files, 0 failures
Scenarios: 33 files, 33 unique IDs, 67 steps
Duplicate IDs: 0; parse/shape errors: 0; formatting notices: 33
FORMAT M1-BOUNCE-01.json: missing final newline
```

Временная venv была только в /private/tmp; project/system settings не менялись.
Проверены good input, missing directory, malformed YAML/JSON, duplicate JSON id
и ключ, missing mandatory shape, strict-format exit; hash source до/после совпал.

## Окружение Cursor BE-23

После `swift build` запустите `python3 tools/check-cursor-environment.py --bin-dir "$(swift build --show-bin-path)"`.
Скрипт проверяет настоящий daemon/private stdio и SQLite на синтетическом CLI:
startup flags, capabilities, настройку и событие, replay, каталог, report,
перезапуск и причины недоступности. CLI-fixture допускает только бесплатные
пробы. Новые данные и результат остаются в `/tmp/kaban-be23-*`.
Discovery login shell, атомарность и отсутствие резервирования проверяются
DaemonCore tests. Положительный login, авторизованный каталог и installed helper
остаются в BE-22 и отдельной системной приёмке.
[Отчёт BE-23](../docs/development/backend-be-23-2026-10-15.md).

## Нативный редактор pipeline

После сборки Kaban.app:

```sh
python3 tools/check-pipeline-editor.py --app /tmp/kaban-context-app/Build/Products/Debug/Kaban.app
```

macOS/Xcode и настоящий WindowGroup, private stdio daemon, восемь запусков.
Script создаёт отдельные Git-репозитории/БД в `/tmp/kaban-fe13-*`; JSON, logs,
PNG и файл после применения остаются там для проверки. Проверяет native field,
⌘↩, отдельные drafts проектов, malformed YAML/Auto/warnings, внешний edit,
apply/version/WIP и restart; снимает light/dark/minimum/long/absent окна.
Capture success не заменяет просмотра PNG. Signed helper registration, system
permissions, VoiceOver и живой Cursor не проверяются; платные CLI не запускаются.

## Тексты диагностик FE-25

`check-pipeline-editor.py --validation-messages` проверяет root type_mismatch,
invalid_id и git_unknown_command в настоящем WindowGroup, light/dark minimum.
Серверные диагностики идут через production daemon/private stdio на synthetic
YAML; error блокирует Apply, warning допускает Apply. Проверка не применяет
черновик и сверяет неизменность исходного файла. [Отчёт FE-25](../docs/development/frontend-fe-25-2026-10-09.md).

## Инциденты FE-19

`seed-incidents.swift` создаёт private Git/store fixture через production APIs.
`check-incidents.py` проверяет настоящий WindowGroup и bundled stdio daemon,
включая скрытые/удалённые проекты, model-without-resume, явный возврат,
retention/restart и отсутствующий лог. Future kind отдельно подставляется в
serialized DTO private fixture после реального rollback. Mac в fixture на паузе;
Cursor CLI и регистрация службы не используются. Команды сборки seed и запуска,
проверенные кадры и ограничения — в
[отчёте FE-19](../docs/development/frontend-fe-19-2026-10-09.md).

## Настройки Мака FE-20

`seed-mac-settings.swift` готовит private production store и явно задаёт
producer-boundary quota/flags fixtures. `check-mac-settings.py` запускает
настоящий WindowGroup и bundled stdio daemon, проверяет typed settings,
паузы, consent/revoke, process restart, native menu route, nil/stale/fresh,
совместные flags и offline draft. Каждый запуск проверяет освобождение writer lease.
Токен, HTTP Cursor, платный prompt и системная регистрация не используются.
Команды, source, кадры и открытая UC-21 приёмка — в
[отчёте FE-20](../docs/development/frontend-fe-20-2026-10-09.md).

## Менюбар и уведомления FE-21

`check-menubar.py` использует private fixture `seed-human-answers.swift` и
проверяет closed-window live updates, reopen, exact/stale/deleted notification
routes и настоящий Quit. `--functional-only` возвращает отдельный частичный
статус и не проверяет popup. `--manual-popup` ждёт ручного клика до пяти минут,
сохраняет настоящий popup и status item, затем оставляет App открытой ещё минуту
перед проверкой Quit. QA проверяет фактическую native appearance по `--theme`.
Без открытого MenuBarExtra строгий сценарий завершается ошибкой. Схлопнутый
popup также считается ошибкой, но его PNG сохраняется для диагностики.
Ни один режим не запрашивает permission, не доставляет
OS notifications и не регистрирует mainApp/helper. Команды и ограничения —
[отчёт FE-21](../docs/development/frontend-fe-21-2026-10-09.md).

## Состав App FE-34

`check-app-build-contents.py --app <Kaban.app>` проверяет реальные Mach-O символы
production Release: демо и QA types отсутствуют, общие Kaban UI types присутствуют.
С `--qa` проверка требует BoardQA, AppFixture и NativeWindowCapture; при наличии
Debug dylib читает и его. Демо types запрещены в обеих конфигурациях.
Debug включает KABAN_QA, Release по умолчанию не включает. CI собирает и проверяет
оба варианта. [Приёмка FE-34](../docs/development/frontend-fe-34-2026-10-09.md).


## Локальная подпись BE-21

`package-local-app.sh` собирает ad-hoc Release с Hardened Runtime и запускает
`check-local-app-signing.py --app <bundle>`. Проверка читает подписи настоящих
App/helper/shim, требует `app.kaban.desktop` / `app.kaban.agent` /
`app.kaban.git-shim`, runtime и отсутствие
`com.apple.security.app-sandbox`. Она не регистрирует службу и не заменяет
проверку SMAppService, одобрение macOS или reboot.

### Проверка git shim (BE-27)

`python3 tools/check-git-shim.py --shim <абсолютный путь к KabanGitShim>`
проверяет собранный executable через временный loopback HTTP-сервер: exact
argv/cwd, stdin/streams/exit code настоящего executable, отказ политики,
неверный JSON/HTTP, redirect, таймаут, отсутствующие env и недоступный демон.
Cursor и системный LaunchAgent не запускаются. Можно передать shim из
`.build/debug/` или `Kaban.app/Contents/MacOS/`; обе формы проверяет CI.

### Настройка Cursor (FE-23)

`python3 tools/check-cursor-setup.py --app <Debug Kaban.app>` запускает 11
сценариев настоящего WindowGroup с private stdio daemon и синтетическим CLI.
Проверяет missing/not-runnable/logged-out, inline refusal, configure + точное
событие в SQLite, login recovery через recheck, persisted path после restart,
offline draft и настоящий model picker. Светлая/тёмная темы, длинный путь,
content viewport 1040×608 и обычный размер сохраняются в `/tmp/kaban-fe23-*`
вместе с JSON/logs. Все вызовы CLI ограничены version/status/list-models.
Регистрацию helper, системные permissions и установленный XPC этот smoke
не выполняет. [Границы FE-23](../docs/development/frontend-fe-23-2026-10-28.md).
