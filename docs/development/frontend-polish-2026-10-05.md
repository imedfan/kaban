# PR #67: исправление основного SwiftUI-интерфейса

Проверка 5 октября 2026 на macOS 27.0.1. База — `origin/main` после #68,
`960a190`; исправление продолжает существующий PR #67 на отдельной ветке
`codex/frontend-polish`. Источники — `design/README.md`, композиция доски base / v0.2,
карточки suspicious v0.2.1 и общие light/dark токены. Динамические DTO fixtures
не воспроизводят весь состав данных старых PNG; попиксельный паритет не заявляется.

Основной WindowGroup использует BoardView / BoardStore / KabanClient /
BoardProjection. AppFixture передаёт Protocol DTO в существующий MockKabanClient.
Отдельные ReferenceDemo / NativeShell больше не являются основным runtime;
исходники сравнения сохранены. Бэк, Cursor и системная регистрация не запускаются.

## Что исправлено

- Подписи главных кнопок видны; стабильные размеры и ритм 4/8/12/16/24.
- Общая композиция сайдбара, шапки и дорожек; пропорциональные колонки,
  одинаковая высота колонок дорожки, закрываемые пустые проекты.
- Нативные карточки: маскот и фактура проекта, идентификатор сверху,
  статус с символом и семантическим цветом снизу. Длинный текст не сжимает
  соседние карточки по вертикали.
- Детали поверх доски сохраняют ширину колонок. Markdown заголовки, списки,
  inline-форматирование и code blocks отображаются нативно; исходник редактора
  сохраняется точно. Unknown body остаётся неизвестным.
- Поиск, фильтры внимания, формы create/edit/move/cancel, task pause/resume
  используют существующие типизированные данные и команды. Pending state
  снимается correlated event, статус не меняется по одному receipt.
- Cmd-N исправлен: старое disabled-состояние меню оставалось после асинхронной
  загрузки. Cmd-F фокусирует поиск; Escape закрывает детали.
- Настройки проекта показывают известные snapshot values; отсутствующие
  quota, effective policy и identity не заменяются выдуманными данными.
- CI вызывает `--ui-smoke` нового runtime; README больше не описывает WebKit.

## Проверки

Unsigned `xcodebuild` — успешно. `KABAN_SCENARIOS=Scenarios/M1 swift test
--filter KabanBoardCoreTests` — 66 tests, 0 failures. Context checker — успешно,
172 оригинала дизайна и 28 reference PNG сохранены без изменения. `git diff
--check` — успешно.

`--ui-smoke` запускает настоящий WindowGroup, проверяет create → correlated
selection и сохранение Markdown, edit/move/cancel, pause/resume → queued,
поиск/фильтры и реальные пункты меню Cmd-N/Cmd-F. Результат —
[ui-smoke.json](ui-qa-2026-10-05/ui-smoke.json).

Layout captures снимались с настоящего WindowGroup, после подготовки состояния
и layout. QA использует изолированное in-memory хранилище board preferences.
Экспорт перемонтирует тот же subtree окна, чтобы AppKit cache включал неизменённые
controls; отдельный ReferenceFrameView не создаётся. Sheets захватываются со своих
настоящих NSWindow и компонуются в позициях над окном приложения.

| Состояние | Результат / сохранённый кадр |
|---|---|
| Доска 1440×900 | [light](ui-qa-2026-10-05/board-light.png), [dark](ui-qa-2026-10-05/board-dark.png) |
| Минимальное окно 1040×640 | [light](ui-qa-2026-10-05/minimum-light.png), горизонтальная прокрутка |
| Suspicious details | [light](ui-qa-2026-10-05/details-light.png), dark также проверен |
| Создание | [минимальное окно](ui-qa-2026-10-05/create-minimum.png), поля/кнопки помещаются |
| Проект | [settings](ui-qa-2026-10-05/project-light.png) |
| Длинные title / ID | [long](ui-qa-2026-10-05/long-light.png), ограничение строк и middle truncation |
| Edit, move, cancel | Layout проверен, кнопки и причины запрета помещаются |
| Пустые проекты / все скрыты | Layout проверен, сохранены global counts и действие создания |
| Поиск без результата | Layout проверен, видны empty column placeholders |
| Ошибка команды | Нативный alert проверен по layout; compositor не подтверждён |
| Human Review | Layout деталей в dark проверен; решений approve/return в текущем клиенте нет |

## Границы приёмки

AppKit cache показывает layout, но не подтверждает финальную картинку оконного
композитора: native window buttons неактивны на capture, у системного alert есть
чёрные углы, у sheet не воспроизводится системная маска/тень. `screencapture -l`
для окна Kaban завершился `could not create image from window`; системный снимок
в этой среде получить не удалось. Поэтому эти файлы не являются попиксельной
приёмкой эффектов macOS.

Ручные pointer-сценарии, сквозная клавиатурная навигация/focus, VoiceOver,
Reduce Transparency / Increase Contrast и отдельные renderer-проверки markdown
таблиц/вложенных списков не выполнены. Маскоты статичны.

Полные редакторы pipeline/git/MCP/identity/quota, add-project/onboarding,
Human Review decisions, принятие файлов, global/project pause и менюбар
остаются работой следующего инкремента. Текущие project settings — просмотр
известных DTO, не замена утверждённых редакторов. Fake string demo прежнего PR
не является доказательством реализации этих сценариев. Реальный XPC/daemon
transport также не подключён. Требования не изменены ради текущего UI.
