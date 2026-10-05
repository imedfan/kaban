# Kaban: закреплённые визуальные источники

Срез оригинальных дизайн-архивов v0.1/v0.2/v0.2.1 перенесён в Git 5 октября 2026.
Файлы скопированы без перерисовки и изменения байтов. [manifest.json](manifest.json)
содержит SHA-256, размер, размеры PNG и исходные Drive-ссылки, где они доступны.
Для обычной разработки внешнее подключение и временные /tmp-папки не требуются.

## Приоритет и использование

Текущее поручение пользователя и утверждённые поведенческие решения имеют приоритет.
Визуально новая версия дополняет предыдущую: v0.2.1 для suspicious files, возвратов,
git/identity; v0.2 для моделей/квоты/флагов; base для остальных компонентов.
Основная доска собирается из этих актуальных компонентов, не из одного старого PNG.
Имена команд/DTO сверяются с Protocol; fixtures старых макетов не продуктовый автомат.

Основное приложение реализуется нативным SwiftUI. HTML/CSS/SVG используются
для изучения композиции и токенов, PNG — для сравнения. Они не являются WebKit runtime.
Для screenshot QA выбери одинаковый viewport, тему и данные; проверяй настоящее
окно приложения с toolbar, safe areas, inspector и действиями. Галерея отдельно
отрендеренных компонентов не заменяет этот результат.

## Токены и исходники

- [tokens.css](tokens.css) — общие light/dark токены; [v021.css](v0.2.1/v021.css) — актуальные дополнения.
- [board.css](board.css) / [board.js](board.js), [v02.css](v0.2/v02.css) / [v02.js](v0.2/v02.js) — композиция доски и флагов.
- [v021.js](v0.2.1/v021.js) — актуальные карточки/доска; детали — [details21.js](v0.2.1/details21.js).
- [Brand](../docs/design/brand.md) — оригинальный значок/wordmark, включая исходники и лицензию шрифта.
- [Mascots](../docs/design/mascots.md) — оригинальный кит и test vectors; SwiftUI ref — справочный пример, не отдельный runtime.

Цвет означает состояние, проект — маскот и фактуру края. Статус находится в нижней
строке карточки. Красный — incident; suspicious_files использует янтарный waiting
и exclamationmark.shield; review — бирюзовый. Полные требования — [frontend plan](../docs/frontend-plan-v0.md).

## Основные кадры

| Экран | PNG |
|---|---|
| Доска, модели и флаги | [light](v0.2/png/01-board-limits-flags.png), [dark](v0.2/png/01-board-limits-flags-dark.png) |
| Базовая композиция доски | [light](png/01-board.png), [dark](png/01-board-dark.png) |
| Карточки/состояния | [v0.2](v0.2/png/02-cards-states.png), [suspicious](v0.2.1/png/01-cards-suspicious.png), [лимиты](v0.2.1/png/01c-cards-bounce-limits.png) |
| Детали suspicious | [light](v0.2.1/png/02-details-suspicious.png), [dark](v0.2.1/png/02-details-suspicious-dark.png), [stale](v0.2.1/png/02b-details-suspicious-stale.png) |
| Incident / Human Review | [incident](png/03-task-details.png), [review](png/03b-human-review.png) |
| Git проекта / стадии | [проект](v0.2.1/png/03-project-git-presets.png), [стадия](v0.2.1/png/04-stage-git-overrides.png) |
| Возврат gate / merge | [gate](v0.2.1/png/05-return-sheet-gate.png), [gate dark](v0.2.1/png/05-return-sheet-gate-dark.png), [merge](v0.2.1/png/05b-return-sheet-merge.png) |
| Добавить проект / identity | [light](v0.2.1/png/06-add-project-identity.png), [dark](v0.2.1/png/06-add-project-identity-dark.png) |
| Pipeline / MCP / quota | [pipeline](v0.2/png/04-pipeline-invalid.png), [MCP](v0.2/png/05-project-mcp.png), [quota](v0.2/png/06-mac-quota-menubar.png) |
| Общие настройки стадии | [general](png/05-column-settings-general.png) |

Все 28 уникальных reference PNG находятся в manifest. Два одинаковых Drive-дубликата
git-кадров не скопированы повторно. Создание задачи/пустая доска не имели оригинальных
кадров; часть настроек suspicious files отложена в источнике. Для них применяются
существующая визуальная система и нативные controls; неподготовленный кадр отмечается явно.

## Происхождение и проверка

Полные документы дизайнера с локальной навигацией — [docs/design](../docs/design/README.md).
Исходные байты заметок сохранены в [reference-notes](reference-notes/base.md):
[base](reference-notes/base.md), [v0.2](reference-notes/v0.2.md), [v0.2.1](reference-notes/v0.2.1.md).
Они описывают исторические версии и исходную структуру. Старые build.sh требуют
непоставленных tools/shot.js и renderer dependencies; не считай их готовым способом
проверки App. Готовые оригинальные PNG уже сохранены.

`python3 tools/check-project-context.py` проверяет ссылки рабочего контекста и
целостность всех оригиналов. При намеренном обновлении дизайна обнови manifest
и соответствующую приёмку, сохранив происхождение новой версии.
