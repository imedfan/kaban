# Read-only smoke tools — T11

Python 3.9+, без SwiftPM и изменений CI. YAML smoke использует
[PyYAML SafeLoader](https://pyyaml.org/wiki/PyYAMLDocumentation), dependency
зафиксирована в requirements.txt. Системный Python менять не требуется:

```sh
python3 -m venv .venv-team2-tools
.venv-team2-tools/bin/python -m pip install -r tools/requirements.txt
.venv-team2-tools/bin/python tools/lint-examples.py
python3 tools/scenarios-report.py
```

Запускайте из корня checkout; default пути вычисляются относительно scripts,
поэтому сами Python команды также работают из другого current directory.
examples/pipelines появятся после [T7 branch](https://github.com/imedfan/kaban/tree/team2/examples-t7-pipelines).
До принятия T7 передайте directory этого checkout первым аргументом.
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
