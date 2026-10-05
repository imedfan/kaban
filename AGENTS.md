# Kaban: инструкции проекта

Kaban — основной проект пользователя. Разрабатываем полноценное локальное
macOS-приложение на SwiftUI и headless-ядро для запуска Cursor CLI по пайплайну.
Исторические ограничения «второй команды» отменены: порученная работа может
менять production-код, существующие тесты, Package.swift, CI и документы.

## Начало задачи и источники

- Проверь `git status --short`, текущую ветку и базу: отчёт о PR не означает, что код есть в checkout.
- Прочитай `docs/current-state.md` и `docs/contributing.md`.
- Текущее поручение пользователя приоритетнее документов. Утверждённые решения — `docs/decisions-log.md`.
- Требования ведутся в Git; вход — `docs/README.md`. Drive импортирован и остаётся историческим источником.
- `docs/architecture-v0.md` задаёт контракт, `docs/kaban-mvp-features-usecases.md` — пользовательское поведение.
- Если код расходится с требованиями, покажи конкретное расхождение; не переписывай требования ради текущего кода.
- Читай нужные разделы по маршрутам ниже. Не загружай весь docs/ или архив для обычной задачи.
- `docs/archive/`, `docs/team2/` и старые отчёты development — исторические материалы, не действующая политика.
- Пути в документах относительны корню репозитория. Старые `/workspace/kaban` и чужие `/tmp` не рабочая база.

## Модули

- `Sources/KabanProtocol/` — Codable DTO, команды, события, идентификаторы и причины состояний.
- `Sources/KabanKit/` — YAML/pipeline, git-policy и чистый автомат; использует Protocol.
- `Sources/KabanDaemonCore/` — GRDB/SQLite, миграции, журнал, effects, fake driver и scheduler.
- `Sources/KabanBoardCore/` — клиентский интерфейс, проекция, pending commands, BoardSet, presentation; только Protocol.
- `App/KabanApp/` — нативные SwiftUI views и BoardStore; импортирует Protocol/BoardCore, без Kit/GRDB.
- `Scenarios/M1/` — сценарии; источник генерации `Scenarios/gen_m1.py`, формат `Scenarios/README.md`.
- `spikes/` — отдельные эксперименты; не входят в корневой SwiftPM-пакет.
- `design/` — версии оригинальных токенов, HTML/CSS, PNG, бренд и маскоты; вход `design/README.md`.

## Маршруты чтения

- Любой frontend: `docs/frontend-plan-v0.md`, затем `docs/frontend/runtime.md` и документ нужного экрана.
- Доска/карточки: `docs/frontend/board-and-cards.md`; детали/действия: `docs/frontend/task-details.md`.
- Pipeline/git/project settings: соответствующие файлы `docs/frontend/*settings.md`.
- Проекты/онбординг: `docs/frontend/projects-and-onboarding.md`; квота/менюбар: `docs/frontend/quota-and-menubar.md`.
- Protocol: архитектура §5, `docs/frontend/protocol-fixtures.md`, nearby roundtrip/legacy fixtures.
- State machine: архитектура §3, спецификация нужного UC, `Scenarios/README.md`.
- Store/scheduler: `docs/backend-plan-v0.md`, архитектура §4/§10/§11, `docs/development/m1-headless-contract.md`.
- UI-приёмка: `docs/frontend/acceptance.md`; критерии MVP: `docs/acceptance-criteria-v0.md`.
- Документы дизайнера: `docs/design/README.md`; исследование и презентация читаются только по задаче.

## Контракты, которые легко нарушить

- UI посылает типизированные команды через KabanClient. Карточка меняется после correlated journal event;
  ответ `.ok` сам по себе не меняет статус и не снимает pending operation.
- Mock-клиент использует те же DTO/события и правила. Отдельная строковая модель задач
  с собственными переходами не должна становиться состоянием основного приложения.
- Пауза Мака/проекта останавливает новые запуски; текущие продолжаются. Пауза задачи прерывает её run.
- WIP, агрегаты, настройки, политика и квота приходят от источника состояния. Отсутствующее поле
  означает неизвестность; не подставляй выдуманные значения. TaskDetail.body=nil не равен пустому тексту.
- В store изменение состояния, journal и effect outbox атомарны; повтор commandId не дублирует действие.
- Совместимость DTO проверяй на legacy fixtures. Новые поля не делают старые обязательные поля optional.
- Изменение общего pipeline-валидатора не оправдывается удобством четырёхстадийной fake fixture.

## Работа над UI

- Реализуй основной интерфейс нативным SwiftUI. HTML/CSS/PNG — визуальные источники; не подменяй приложение WebKit.
- До правки выбери экран, пользовательский сценарий и версии макетов из `design/README.md`.
- Сохраняй утверждённую композицию и семантику; переработка дизайна должна следовать поручению пользователя.
- Используй существующий BoardStore/KabanClient/BoardProjection. Превью могут иметь fixtures,
  но реализация действий не должна дублировать автомат и валидатор в views.
- Проверяй настоящее окно приложения: основной сценарий, светлая/тёмная тема, минимальный размер,
  длинный текст, пустые/ошибочные состояния, клавиатура. Фиксируй проверенные экраны и найденные расхождения.
- Экспорт галереи или отдельного ReferenceFrameView не доказывает качество WindowGroup/NativeShell.
- Сборка и unit tests не доказывают визуальную готовность. Непроверенные состояния явно укажи в результате.

## Команды из корня

- Контекст/документы/исходники дизайна: `python3 tools/check-project-context.py`.
- Ядро: `swift build`; полный прогон: `KABAN_SCENARIOS=Scenarios/M1 swift test`.
- Узкий прогон: `KABAN_SCENARIOS=Scenarios/M1 swift test --filter <Suite>`; имя бери из реальных Tests/.
- Приложение: `xcodebuild -project Kaban.xcodeproj -scheme Kaban -destination 'generic/platform=macOS' -derivedDataPath /tmp/kaban-context-app ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`.
- SwiftPM: Swift 6.1+, macOS 15+ или Linux; на Linux нужны SQLite headers. Приложение: macOS 26+, полный Xcode.
- Без KABAN_SCENARIOS часть проверок пропускается. Корневой swift test не проверяет SwiftUI views и спайки.
- Сбой внешней среды не исправляй ослаблением тестов; запиши причину и используй допустимый способ проверки.

## Завершение

- Работай в отдельной `codex/…` ветке от актуальной базы; не сбрасывай чужие изменения. PR направляй в main.
- Мерж выполняет Артём, пока пользователь явно не поручит его агенту. Системная регистрация и платные CLI не обычный smoke.
- Для кода проверяй изменённое поведение и затронутые suites; для App отдельно собери и проверь настоящее окно.
- Для правок только документов/дизайн-источников достаточно context checker и проверки diff; не добавляй зеркальные тесты.
- Обновляй `docs/current-state.md`, когда меняется реализованная поверхность или основной путь приложения.
- Перед завершением проверь diff и сообщи результат проверок, пропуски и оставшуюся работу.
- Demo/fake pipeline, green CI и отчёт прошлой ветки не означают готовность полного M1/MVP.
