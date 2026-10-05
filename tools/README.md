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
