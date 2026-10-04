# Примеры pipeline — T7

Источник: architecture v0.11.22 §3.1, spec v0.8.24 §1.5/§4.1.
Baseline `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`, 2026-10-04.
Моделей по умолчанию нет: **замените каждый `<model-id>`** явным id из
`cursor-agent --list-models`. `auto` запрещён. Плейсхолдер — шаблон,
а не подтверждение наличия модели или готовности Cursor к запуску.
Текущий validator проверяет строку модели, не доступность id в Cursor.

| Файл | Процесс |
|---|---|
| default.yaml | Backlog → Dev → Test → AI Review → Human Review → Merge → Done; defaults 3/2/2/5, read-only reviewer |
| minimal.yaml | Backlog → Dev → Merge → Done; один writable agent |
| strict-review.yaml | Dev + read-only Review + Human Review; strict git, коммитит демон |
| with-gates.yaml | Отдельный gate с `swift build`/`swift test`, on_fail → Dev |

Проверьте gate команды для своего проекта до применения. Skills paths в default
требуют настоящих файлов `.kaban/skills/*.md`; сами skills здесь не поставляются.
Strict git ограничивает **git-команды**, permissions=write у Dev разрешает
редактирование файлов; read-only reviewer отдельный. MCP доски всегда доступен.
Примеры не записывают `.kaban/`, не запускают агента и не изменяют pipeline проекта.

[invalid](invalid/README.md) — синтаксически правильный YAML с намеренными
семантическими ошибками. Не применяйте их как рабочий pipeline.

Проверка выполнена на macOS/Swift6.4: MiniYAML разбирает все 11 файлов;
после замены `<model-id>` → `composer-2` четыре positive файла валидны без issues,
каждый invalid даёт ожидаемый code. Семь negative также проверены ниже.
Использован временный harness с неизменёнными Sources/KabanProtocol и KabanKit,
ничего не подключено к SwiftPM/Tests/CI (так требует T7).
Логи координатора: `/private/tmp/kaban-team2-context/T7-validation.log`.
Для повтора основной Backend может прочитать каждый файл и вызвать
`PipelineValidator.validate(yaml:)` после подстановки доступной модели.
Это проверка схемы, не исполнение gates/CLI/MCP/merge.

Опорные документы:
[архитектура](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view),
[спецификация](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view),
[сверка 37 кодов AN4](https://github.com/imedfan/kaban/pull/18).
