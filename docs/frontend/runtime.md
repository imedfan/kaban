# Kaban: frontend runtime и состояние

Основной интерфейс — нативный SwiftUI в `App/KabanApp/`. Текущее состояние —
[current-state](../current-state.md); маршруты экранов — [frontend-plan](../frontend-plan-v0.md).

## Реальные точки входа

- `App/KabanApp/KabanApp.swift` создаёт DaemonRuntime: SMAppService + DaemonKabanClient по XPC; `--developer` использует встроенный helper по private stdio. AppFixture включается только в явном UI QA.
- `App/KabanApp/BoardStore.swift` связывает views с клиентом, проекцией и выбором задачи.
- `Sources/KabanBoardCore/KabanClient.swift` содержит типизированные envelope/reply,
  capabilities, log API, updates и mock. `ClientCommandJournal` сохраняет точную
  отправку и metadata ответа для последующего reconciliation.
- `BoardProjection`, `PendingCommands`, `BoardSetStore`, `DropRules` находятся в BoardCore.
- Protocol DTO и команды находятся в `Sources/KabanProtocol/`.

BoardCore зависит только от Protocol, без SwiftUI/AppKit. Приложение не импортирует
Kit/GRDB. DaemonKabanClient реализует существующую клиентскую границу и передаёт connection/replacement/journal/ephemeral из sessionUpdates. Установка SMAppService пока блокируется Sandbox; [проверки BE-20](../development/backend-launch-agent-2026-10-06.md).
Отдельные KabanUI/KabanAppTests/KabanUITests из старого плана — предложения;
в текущем проекте таких targets нет. Не создавай их только ради совпадения с планом.

## Команды и authoritative events

View вызывает метод store; store сохраняет точный CommandEnvelope до отправки
через KabanClient. CommandReply сохраняет commandId/seq/result. Capabilities
проверяются при handshake и новом connected, включая перезапуск сервера.
Ответ `.ok` не переводит карточку. Pending command снимается correlated событием
или отказом. Для создания учитывай событие до ответа; повтор commandId не создаёт
дубликат. Ошибка сохраняет пользовательский ввод. Потеря ответа отмечает неопределённую
доставку; исходный envelope не заменяется новым commandId. FE-02 завершает replay
после reopen/retention. Correlated journal подтверждает изменение состояния,
но не завершение внешнего effect (например restoreWIP).

Snapshot и подписка должны согласовываться по seq. Duplicate/old события
отбрасываются, gap требует resync. Новый snapshot сверяет видимые проекты и
выбранную задачу; результаты getTaskDetail защищаются task ID, generation и seq.
Удаление выбранной задачи закрывает детали, а не показывает старый результат.

DTO задают единственные статусы/причины и типы настроек. Mock работает с теми же
DTO, командами и событиями. Превью допустимы; второй автомат на строковых
ReferenceTask/status внутри основного приложения создаёт несовместимые правила.

WIP берётся из StageLoad; incident aggregates — из ProjectSummary. Отсутствующее
settings/quota/policy поле означает неизвестность. TaskDetail.body=nil нельзя
перезаписать пустой строкой. Markdown должен сохраняться без потери текста.

Пауза Мака/проекта блокирует новые запуски, но не переводит текущие running
карточки в paused. Пауза задачи прерывает её run. Resume исполняемой стадии
возвращает queued; явная пауза из Human Review сохраняет admission и возвращает
waiting_human: review. Клиент применяет результат демона, не угадывает его.
DropRules помогает интерфейсу, а окончательное разрешение даёт клиент/демон.
Pipeline validation и вычисление итоговой git-политики выполняются за клиентской границей.

## Требования к сессии и последующим экранам

Durable wire-инкремент backend добавляет `SettingsChange.schedulerFlags`:
полный набор флагов в correlated journal event. Nil/отсутствие оставляет текущее
значение, `[]` снимает флаги. BoardProjection уже принимает это поле и typed
`settings` из snapshot/settingsChanged. Adapter сохраняет порядок
journal и live ephemeral updates; `.ok` не является применением паузы/настроек.

Подписка охватывает все проекты (`projectIds=nil`), а набор дорожек хранится
отдельно в UserDefaults. Значки скрытых проектов и менюбар используют полную
проекцию. Incident-события обновляют ленту; агрегаты меняются через ProjectSummary.
События деталей до ответа getTaskDetail буферизуются, затем применяются только
с seq больше seq ответа. Snapshot/subscription handshake, reconnect и resync
должны сохранять эту границу; во время догонки команды недоступны.

ConnectionStore, SchedulerStore, PipelineEditorStore, ModelCatalogStore и LogStore
из [полного исходного плана, §2](../archive/2026-10-04/frontend-plan-v0.md)
описывают предложенное разбиение будущей реализации. Текущий BoardStore не
реализует все эти поверхности. Читай этот раздел при работе над подключением,
логами или настройками; названия не требуют создания отдельных targets.
Точные wire-типы и семантика — архитектура §5 и Sources/KabanProtocol/;
поздние решения уточняют старые примеры и предложения плана.

## Проверка реализации

Сначала проверь nearby BoardCore tests и реальные DTO. Изменение поведения
должно проверяться командами/событиями, включая отказы, stale result и повтор.
Проверь app build и основной пользовательский сценарий в настоящем окне.
Рендер отдельного ReferenceFrameView не заменяет проверку WindowGroup.
Матрица экранов/доступности — [acceptance](acceptance.md); визуальные источники — [design](../../design/README.md).
