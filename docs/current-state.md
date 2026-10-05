# Kaban: текущее состояние

Срез 5 октября 2026. Kaban — основной проект Артёма. Разработка не ограничена
ролью «второй команды»; действующие правила — [contributing](contributing.md)
и [AGENTS.md](../AGENTS.md). Документы и оригиналы дизайна доступны в Git.

## База этого среза

Проверенная после git fetch база реализации: `origin/main` —
`69dbacf9fcce77662d6b495adc0f240ee1d7b4ff` (приняты #63–66).
Ветка правки контекста основана на этой базе. Локальная ветка с именем main
может быть старее origin/main; перед новой задачей проверь refs и diff.
Этот документ описывает код базы, а не обещания из старых планов.

## Что есть в основном коде

| Область | Реализовано | Граница |
|---|---|---|
| Protocol | Типизированные команды, snapshot/details, события, settings, optional Markdown body, legacy decoding | Наличие DTO не означает готовый транспорт |
| Kit | YAML/pipeline validation, git-policy, автомат, retry/return/pause rules | Не является процессом демона |
| DaemonCore | GRDB store, миграции, durable state/journal/effects, bounded fake driver, scheduler, recovery | Git/process effects симулируются |
| BoardCore | KabanClient/MockKabanClient, проекция seq/events, pending commands, BoardSet, DropRules, presentation | Отдельный чистый клиентский слой |
| Kaban.app | SwiftUI BoardView/BoardStore, mock-доска, create/edit/move/cancel, детали, pause/resume | Нет связи с DaemonCore через XPC |
| Design | Оригиналы токенов и исходников, 28 уникальных PNG, бренд и mascot kit | Наличие макетов не означает визуальную приёмку приложения |

Mock-задачи живут в памяти текущего запуска. Набор видимых проектов сохраняется
в UserDefaults. Настройки, квота и фактические агентские процессы пока не подключены.
Полный M1/MVP не принят; ограничения fake engine описаны в
[headless contract](development/m1-headless-contract.md).

## Ветки UI за пределами main

В срезе сохранены `codex/frontend-design-parity` и `codex/native-swiftui-parity`.
Последняя исследованная нативная версия — `d8def915ecc669ef7e1a7556bacc8d3017343519`.
Эти эксперименты не входят в указанную базу main и не являются источником
продуктовых правил. Перед использованием повторно проверь их актуальность.

Аудит выявил отдельный ReferenceDemo с собственными строковыми статусами,
переходами и настройками; глобальная пауза там меняет running-задачи вопреки
спецификации. Экспорт ReferenceFrameView и основное окно NativeShell также
проверяются разными путями. Старые README эксперимента описывают удалённый WebKit.
При переносе нативных компонентов сначала подключи их к существующему
BoardStore/KabanClient и проверь настоящее окно. Галерея остаётся инструментом сравнения.

## Ближайшие результаты

1. Нативная доска и детали по закреплённым макетам на текущей типизированной
   клиентской модели; визуальная проверка основного окна и действий.
2. Daemon host/XPC adapter: snapshot/subscription handshake, reconnect/resync,
   retry того же commandId и durable backend команды для frontend-действий.
3. Реальные Cursor/git/MCP/gates, целевые isolation-спайки и квота.
4. Полная сценарная, визуальная и доступностная приёмка; упаковка/подпись.

Это порядок ориентации, а не запрет выполнять другую явно порученную задачу.
Каждый инкремент должен давать проверяемый пользовательский результат.

## Какие источники читать

- [Архитектура](architecture-v0.md) — контракт и границы; [спецификация](kaban-mvp-features-usecases.md) — поведение.
- [Frontend plan](frontend-plan-v0.md) — маршруты к отдельным экранам; [backend plan](backend-plan-v0.md) — исполнитель.
- [Design](../design/README.md) — версии, токены и PNG; [приёмка](acceptance-criteria-v0.md) — MVP.
- [Журнал решений](decisions-log.md) — утверждённые изменения; новые решения должны попасть в соответствующий рабочий документ.
- [Архив](archive/README.md) и [team2](team2/README.md) — происхождение и старые аудиты, читаются по необходимости.

Документация ведётся в Git. [Источники Drive](README.md) сверены и перенесены;
более свежие версии Git сохранены. Drive остаётся внешним историческим источником.
Старые publication manifests относятся к прежним публикациям и не означают
актуальность документов. Для работы внешнее подключение не требуется.

Команды сборки и ограничения среды — [getting started](getting-started.md).
Обновляй этот срез при изменении основного entry point, реализованных функций или границ интеграции.
