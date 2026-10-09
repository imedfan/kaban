# Инструменты проверки Kaban

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

## Тексты диагностик FE-25

`check-pipeline-editor.py --validation-messages` проверяет root type_mismatch,
invalid_id и git_unknown_command в настоящем WindowGroup, light/dark minimum.
Серверные диагностики идут через production daemon/private stdio на synthetic
YAML; error блокирует Apply, warning допускает Apply. Проверка не применяет
черновик и сверяет неизменность исходного файла. [Отчёт FE-25](../docs/development/frontend-fe-25-2026-10-09.md).
