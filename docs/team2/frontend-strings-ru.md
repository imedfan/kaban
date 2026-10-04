# F-T2-4 — каталог русских строк интерфейса

Снимок источников: 4 октября 2026; frontend-plan-v0.md **v0.5.36**, kaban-mvp-features-usecases.md **v0.8.24**, architecture-v0.md **v0.11.22**, acceptance-criteria-v0.md **v0.1**. Источники получены из папки kaban/docs; [репозиторий](https://github.com/imedfan/kaban). Номера строк ниже относятся к этим свежим снимкам, не к старым файлам репозитория.

Предложены ключи для будущего String Catalog, production-код не менялся. Текст в таблицах сохранён точно, включая регистр, многоточия, вложенные кавычки и конкретные числа в примерах. Основным действиям предложены смысловые ключи; сегмент `textNNN` — временный идентификатор прочих фрагментов в пределах экрана; при переносе в String Catalog следует закрепить смысловые имена. Пример с числом не является утверждённым шаблоном: имена динамических подстановок в колонке — предложение, текст не переписан. Фрагменты с `/` и многоточием, заданные планом сокращённо, требуют согласования отдельных вариантов до реализации.

Макеты, design/**, контраст, раскладки, тёмные темы и дизайн маскотов исключены человеком. Сверка **план ↔ макет не выполнена именно из-за этого исключения**. Упоминание макета в цитате плана не означает его проверки.

## Покрытие экранов и отсутствие текста

| Раздел | Экран / компонент | Покрытие / не заданная подпись |
|---|---|---|
| §3 Drag-and-drop | Доска / drag карточки, подтверждение | 1 точных фрагментов; отдельные пробелы ниже |
| §3.1 | Баннеры / SchedulerBanner, PoolBanner, ModelBanner, LaneHeader | 30 точных фрагментов; отдельные пробелы ниже |
| §3.2 | Дорожка / StageColumnHeader, GateStripView | 2 точных фрагментов; отдельные пробелы ниже |
| §3.3 | Доска / SwimlanesView, KindGroupedBoardView | 3 точных фрагментов; отдельные пробелы ниже |
| §3.4 | Карточка / статус, бейджи, контекстное меню | 74 точных фрагментов; отдельные пробелы ниже |
| §3.5 | Панель / TaskInspector, SuspiciousFilesBlock, ReturnSheet | 83 точных фрагментов; отдельные пробелы ниже |
| §3.6 | Лента / GitDenialRow, разрешения git | 19 точных фрагментов; отдельные пробелы ниже |
| §3.7 | Human Review / ReviewView | 14 точных фрагментов; отдельные пробелы ниже |
| §3.8 | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | 42 точных фрагментов; отдельные пробелы ниже |
| §3.9 | Настройки / проект, Git, MCP, автор коммитов | 59 точных фрагментов; отдельные пробелы ниже |
| §3.10 | Добавление проекта / AddProjectFlow, EmptyBoardView | 22 точных фрагментов; отдельные пробелы ниже |
| §3.11 | Онбординг / SMAppService, checkEnvironment | 3 точных фрагментов; отдельные пробелы ниже |
| §3.12 | Менюбар / MenuBarExtra, уведомления | 7 точных фрагментов; отдельные пробелы ниже |
| §3.13 | Квота / QuotaBars, настройки Мака | 10 точных фрагментов; отдельные пробелы ниже |
| §5 | Доступность / карточка, роторы, LaneHeader | 8 точных фрагментов; отдельные пробелы ниже |

| Предлагаемый ключ | Текст | Экран / компонент | Плейсхолдеры | Источник |
|---|---|---|---|---|
| `lane.gate.expand` | нет текста | GateStripView / раскрытие | — | план §3.2: поведение описано, точная подпись не задана |
| `boards.collapsed.summary` | нет текста | Свёрнутая дорожка / сводка | — | план §3.3: поведение описано, точная подпись не задана |
| `inspector.incident.decision` | нет текста | IncidentRow / полный текст решения | — | план §3.5: поведение описано, точная подпись не задана |
| `review.comment.placeholder` | нет текста | ReviewView / плейсхолдер комментария | — | план §3.7: поведение описано, точная подпись не задана |
| `pipeline.stage.add` | нет текста | Список стадий / добавление | — | план §3.8: поведение описано, точная подпись не задана |
| `pipeline.stage.delete` | нет текста | Список стадий / удаление | — | план §3.8: поведение описано, точная подпись не задана |
| `settings.project.path` | нет текста | Общее / подпись пути | — | план §3.9: поведение описано, точная подпись не задана |
| `onboarding.notifications.consent` | нет текста | Онбординг / разрешение уведомлений | — | план §3.11: поведение описано, точная подпись не задана |
| `quota.consent.fullText` | нет текста | Квота / полный текст согласия (заданы смысл и факты) | — | план §3.13: поведение описано, точная подпись не задана |
| `toast.command.invalidState` | нет текста | Тост команды invalid_state / ReviewView | — | план §3.7: поведение описано, точная подпись не задана |

## Точные тексты плана §3 и §5

| Предлагаемый ключ | Точный русский текст / пример | Экран / компонент | Плейсхолдеры / динамические значения | Источник |
|---|---|---|---|---|
| `scheduler.paused.title` | Все запуски на паузе | Доска / SchedulerBanner | — | план §3.1, L64 |
| `scheduler.resume` | Продолжить | Доска / SchedulerBanner | — | план §3.1, L64, L71 |
| `scheduler.text003` | Лимит Cursor, возобновление в 16:40 | Доска / SchedulerBanner | числа/дата/время в примере: шаблон не задан | план §3.1, L65 |
| `scheduler.clearRateLimit` | Снять сейчас | Доска / SchedulerBanner | — | план §3.1, L65 |
| `scheduler.text005` | Om исчерпан до 14.08 · N стадий | Доска / PoolBanner | n (N в источнике), числа/дата/время в примере: шаблон не задан | план §3.1, L66 |
| `scheduler.changeModel` | Сменить модель | Доска / PoolBanner | — | план §3.1, L66, L69, L70 |
| `scheduler.text007` | Квота Cursor исчерпана до 14.08 | Доска / SchedulerBanner | числа/дата/время в примере: шаблон не задан | план §3.1, L67 |
| `scheduler.text008` | Сброс неизвестен, проверка раз в 6 ч | Доска / SchedulerBanner | числа/дата/время в примере: шаблон не задан | план §3.1, L67 |
| `scheduler.text009` | Cursor недоступен: не найден / не запускается / не выполнен вход / ошибка авторизации | Доска / SchedulerBanner | — | план §3.1, L68 |
| `scheduler.recheck` | Проверить снова | Доска / SchedulerBanner | — | план §3.1, L68, L73, L74 |
| `scheduler.text011` | выполните `cursor-agent login` в Терминале | Доска / SchedulerBanner | — | план §3.1, L68 |
| `scheduler.text012` | Opus недоступен · N стадий | Доска / ModelBanner | n (N в источнике) | план §3.1, L69 |
| `scheduler.text013` | Cursor подменяет <модель> · N стадий | Доска / ModelBanner | модель, n (N в источнике) | план §3.1, L70 |
| `scheduler.clearModelFlag` | Снять флаг | Доска / ModelBanner | — | план §3.1, L70 |
| `scheduler.projectPaused` | Проект на паузе | Дорожка / LaneHeader | — | план §3.1, L71 |
| `scheduler.text016` | 3/3 ждут человека — новые задачи из Backlog не берутся | Дорожка / LaneHeader | числа/дата/время в примере: шаблон не задан | план §3.1, L72 |
| `scheduler.projectMissing` | Папка не найдена | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.relink` | Указать путь | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.remove` | Удалить | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.pipelineMissing` | Нет пайплайна | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.createTemplate` | Создать шаблон… | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.pipelineInvalid` | Пайплайн невалиден | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.openSettings` | Открыть настройки | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.pipelineCannotStart` | Пайплайн не запустится | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.text025` | Пайплайн не запустится: нет модели у Dev, Test | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.setModels` | Указать модели | Дорожка / LaneHeader | — | план §3.1, L73 |
| `scheduler.text027` | Запуск не стартовал: CLI видит лишний MCP-сервер «<имя>» | Дорожка / LaneHeader | имя | план §3.1, L74 |
| `scheduler.openMcp` | Открыть MCP | Дорожка / LaneHeader | — | план §3.1, L74 |
| `scheduler.text029` | Слияние ждёт: в `main` есть ваши правки, пересекающиеся с входящими | Дорожка / LaneHeader | — | план §3.1, L75 |
| `scheduler.hideLane` | Убрать с доски | Дорожка / LaneHeader | — | план §3.1, L77 |
| `lane.text001` | 4/3 | Дорожка / StageColumnHeader, GateStripView | числа/дата/время в примере: шаблон не задан | план §3.2, L79 |
| `lane.hiddenStages` | скрытые стадии | Дорожка / StageColumnHeader, GateStripView | — | план §3.2, L79 |
| `boards.hideLane` | Убрать с доски | Доска / SwimlanesView, KindGroupedBoardView | — | план §3.3, L82 |
| `boards.text002` | ждёт человека | Доска / SwimlanesView, KindGroupedBoardView | — | план §3.3, L83 |
| `card.text001` | В очереди #2 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L90 |
| `card.waitingForWip` | Ждёт места | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L90 |
| `card.waitingForSlot` | Ждёт процесс | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L90 |
| `card.text004` | Ждёт квоту Om · сброс через N д | Карточка / статус, бейджи, контекстное меню | n (N в источнике) | план §3.4, L90 |
| `card.text005` | Ждёт модель: Opus недоступен | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L90 |
| `card.priorityFirst` | ↑ первым | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L90 |
| `card.cannotStart` | не запустится | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L90 |
| `card.text008` | Работает 12 мин | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L91 |
| `card.text009` | последнее действие: <текст `report_progress`> | Карточка / статус, бейджи, контекстное меню | текст `report_progress` | план §3.4, L91 |
| `card.text010` | прошло / wall-таймаут | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L91 |
| `card.text011` | Гейты: swift test 2/3 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L92 |
| `card.mergeGates` | Rebase + гейты | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L92 |
| `card.daemonWillCommit` | коммит сделает Kaban | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L92 |
| `card.text014` | Повтор 2/3 через 1:30 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L93 |
| `card.text015` | Всего возвратов | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L93 |
| `card.text016` | продолжит в том же клоне, вывод гейта уйдёт в промпт | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L93 |
| `card.retryAfterRateLimit` | После лимита Cursor | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L94 |
| `card.waitingForRunner` | Ждёт Cursor | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L95 |
| `card.recheck` | Проверить снова | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L95 |
| `card.retryAfterRestart` | Повтор после перезапуска | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L96 |
| `card.probingModel` | Проверяем модель | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L97 |
| `card.text022` | Read-only стадия изменила файлы · повтор через 30 с | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L98 |
| `card.text023` | через 2 мин | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L98 |
| `card.humanQuestion` | Вопрос агента | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L99 |
| `card.answer` | Ответить | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L99 |
| `card.humanReview` | На ревью | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L100 |
| `card.text027` | +128 −40 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L100 |
| `card.text028` | после конфликта | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L100 |
| `card.text029` | Попытки исчерпаны 3/3 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L101 |
| `card.retry` | Перезапустить | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L101, L102, L107 |
| `card.model` | Модель | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L101, L102, L107 |
| `card.text032` | Лимит запусков на задачу, 12 из 12 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L102 |
| `card.runLimit.title` | Лимит запусков на задачу | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L102 |
| `card.text034` | 12 из 12 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L102 |
| `card.text035` | Лимит запусков на задачу · 12 из 12 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L102 |
| `card.agentComment` | Замечание агенту | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L102, L104 |
| `card.text037` | Подмена: <запрошена> → <ответила> | Карточка / статус, бейджи, контекстное меню | запрошена, ответила | план §3.4, L103 |
| `card.retry.variant038` | Повторить | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L103 |
| `card.otherModel` | Другая модель | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L103 |
| `card.toBacklog` | В Backlog | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L103 |
| `card.text041` | Лимит возвратов · при конфликте, 2 из 2 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L104 |
| `card.text042` | <откуда> → <куда>, N из M | Карточка / статус, бейджи, контекстное меню | откуда, куда, n (N в источнике), max (M в источнике) | план §3.4, L104 |
| `card.text043` | Test → Dev, 3 из 3 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L104 |
| `card.text044` | AI Review → Dev, 2 из 2 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L104 |
| `card.bounceLimit.title` | Лимит возвратов | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L104 |
| `card.text046` | общий, 5 из 5 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L104 |
| `card.text047` | при красном гейте, 3 из 3 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L104 |
| `card.text048` | при конфликте, 2 из 2 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L104 |
| `card.grantAttempts` | Ещё N попыток | Карточка / статус, бейджи, контекстное меню | n (N в источнике) | план §3.4, L104 |
| `card.move` | Перенести… | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L104 |
| `card.returnWithComment` | Вернуть с замечанием | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L104 |
| `card.text052` | Модели | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L104 |
| `card.text053` | Политика git: 5 отказов | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L105 |
| `card.text054` | Разрешения… | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L105 |
| `card.text055` | Политика… | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L105 |
| `card.text056` | Подозрительные файлы: 2 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L106 |
| `card.text057` | `.env.local` · по шаблону `.env*` | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L106 |
| `card.text058` | `dump.sql` · больше 5 МБ | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L106 |
| `card.text059` | похоже на секрет | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L106 |
| `card.text060` | +N | Карточка / статус, бейджи, контекстное меню | n (N в источнике) | план §3.4, L106, L113 |
| `card.text061` | перед слиянием | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L106 |
| `card.text062` | Открыть файлы | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L106 |
| `card.text063` | Read-only стадия изменила файлы | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L107 |
| `card.text064` | Инцидент · refs откатаны | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L108 |
| `card.pause` | Пауза | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L109, L115 |
| `card.resume` | Продолжить | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L109 |
| `card.text067` | main грязная | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L110 |
| `card.text068` | Готово 14:05 → main | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L111 |
| `card.text069` | Отменена | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L111 |
| `card.text070` | 1/2 | Карточка / статус, бейджи, контекстное меню | числа/дата/время в примере: шаблон не задан | план §3.4, L113 |
| `card.moveMenu` | Переместить в ▸ | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L115 |
| `card.priorityMenu` | Приоритет ▸ | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L115 |
| `card.cancel` | Отменить… | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L115 |
| `card.keepBranch` | Сохранить ветку | Карточка / статус, бейджи, контекстное меню | — | план §3.4, L115 |
| `inspector.text001` | попытка 2 из 3 | Панель / TaskInspector | числа/дата/время в примере: шаблон не задан | план §3.5, L118 |
| `inspector.openInCursor` | Открыть в Cursor | Панель / TaskInspector | — | план §3.5, L118 |
| `inspector.text003` | … | Панель / TaskInspector | — | план §3.5, L118 |
| `inspector.text004` | Поставить на паузу, чтобы править | Панель / TaskInspector | — | план §3.5, L118 |
| `inspector.text005` | по шаблону `<pattern>` | Панель / SuspiciousFilesBlock | pattern | план §3.5, L121 |
| `inspector.text006` | больше 5 МБ | Панель / SuspiciousFilesBlock | числа/дата/время в примере: шаблон не задан | план §3.5, L121 |
| `inspector.text007` | В исключения проекта… | Панель / SuspiciousFilesBlock | — | план §3.5, L121 |
| `inspector.text008` | дифф | Панель / SuspiciousFilesBlock | — | план §3.5, L121 |
| `inspector.text009` | Показать в Finder | Панель / SuspiciousFilesBlock | — | план §3.5, L121 |
| `inspector.text010` | Проверка всего diff ветки относительно базы; в «Строгом» — и незакоммиченное в клоне | Панель / SuspiciousFilesBlock | — | план §3.5, L121 |
| `inspector.acceptFiles` | Принять файлы | Панель / SuspiciousFilesBlock | — | план §3.5, L122, L123, L138 |
| `inspector.text012` | отправлено | Панель / SuspiciousFilesBlock | — | план §3.5, L122 |
| `inspector.text013` | Kaban сразу перепроверит ветку и продолжит без нового запуска агента | Панель / SuspiciousFilesBlock | — | план §3.5, L122 |
| `inspector.text014` | Набор файлов изменился — ничего не принято | Панель / SuspiciousFilesBlock | — | план §3.5, L123 |
| `inspector.text015` | новый | Панель / SuspiciousFilesBlock | — | план §3.5, L123 |
| `inspector.text016` | изменён | Панель / SuspiciousFilesBlock | — | план §3.5, L123 |
| `inspector.sent` | Отправлено… | Панель / SuspiciousFilesBlock | — | план §3.5, L123 |
| `inspector.askToRemoveFiles` | Попросить убрать | Панель / SuspiciousFilesBlock | — | план §3.5, L124, L139 |
| `inspector.agentComment` | Замечание агенту | Панель / SuspiciousFilesBlock | — | план §3.5, L124, L128 |
| `inspector.text020` | Убери из ветки: <пути> | Панель / SuspiciousFilesBlock | пути | план §3.5, L124 |
| `inspector.text021` | Агент получит новый запуск; после гейтов проверка повторится. Файл, оставшийся в ветке, сработает снова | Панель / SuspiciousFilesBlock | — | план §3.5, L124 |
| `inspector.returnFiles` | Вернуть… | Панель / ReturnSheet | — | план §3.5, L125, L132, L140, L141 |
| `inspector.returnTarget` | Куда | Панель / ReturnSheet | — | план §3.5, L126, L131 |
| `inspector.text024` | только стадии, которые правят код | Панель / ReturnSheet | — | план §3.5, L126 |
| `inspector.text025` | Всего возвратов N/5 | Панель / ReturnSheet | n (N в источнике), числа/дата/время в примере: шаблон не задан | план §3.5, L127 |
| `inspector.text026` | <откуда> → <куда> N/лимит | Панель / ReturnSheet | откуда, куда, n (N в источнике) | план §3.5, L127 |
| `inspector.text027` | ручной возврат счётчики не меняет | Панель / ReturnSheet | — | план §3.5, L127 |
| `inspector.totalBounceLimit` | Общий лимит возвратов | Панель / ReturnSheet | — | план §3.5, L127 |
| `inspector.bounceLimit.title` | Лимит возвратов | Панель / ReturnSheet | — | план §3.5, L127 |
| `inspector.text030` | общий, 5 из 5 | Панель / ReturnSheet | числа/дата/время в примере: шаблон не задан | план §3.5, L127 |
| `inspector.text031` | Test → Dev, 3 из 3 | Панель / ReturnSheet | числа/дата/время в примере: шаблон не задан | план §3.5, L127 |
| `inspector.text032` | при красном гейте, 3 из 3 | Панель / ReturnSheet | числа/дата/время в примере: шаблон не задан | план §3.5, L127 |
| `inspector.text033` | при конфликте, 2 из 2 | Панель / ReturnSheet | числа/дата/время в примере: шаблон не задан | план §3.5, L127 |
| `inspector.text034` | Пусто — файлы будут приняты. Напишите замечание, чтобы вернуть без принятия… | Панель / ReturnSheet | — | план §3.5, L128 |
| `inspector.text035` | Подставить «Убери из ветки: <пути через запятую>» | Панель / ReturnSheet | пути через запятую | план §3.5, L128 |
| `inspector.acceptFilesAndReturn` | Принять файлы и вернуть | Панель / ReturnSheet | — | план §3.5, L129, L141 |
| `inspector.text037` | в принятые · <короткий blob> | Панель / ReturnSheet | короткий blob | план §3.5, L129 |
| `inspector.text038` | Набор принимается… | Панель / ReturnSheet | — | план §3.5, L129 |
| `inspector.returnWithComment` | Вернуть с замечанием | Панель / ReturnSheet | — | план §3.5, L130, L140 |
| `inspector.text040` | останется помеченным | Панель / ReturnSheet | — | план §3.5, L130 |
| `inspector.text041` | Набор не принимается… | Панель / ReturnSheet | — | план §3.5, L130 |
| `inspector.dismiss` | Отмена | Панель / ReturnSheet | — | план §3.5, L131 |
| `inspector.retryStage` | Перезапустить стадию | Панель / ReturnSheet | — | план §3.5, L133, L142 |
| `inspector.toBacklog` | В Backlog | Панель / ReturnSheet | — | план §3.5, L133, L142, L147, L153 |
| `inspector.cancel` | Отменить… | Панель / ReturnSheet | — | план §3.5, L133, L142 |
| `inspector.text046` | Сохранить ветку → `kaban/archive/<id>` | Панель / ReturnSheet | id | план §3.5, L133 |
| `inspector.reject` | Отклонить | Панель / ReturnSheet | — | план §3.5, L133, L143 |
| `inspector.text048` | Вернуть | Панель / ReturnSheet | — | план §3.5, L133 |
| `inspector.text049` | Эти действия примут текущий набор: файлы с этим содержимым больше не сработают; изменённый или новый файл сработает снова | Панель / ReturnSheet | — | план §3.5, L133 |
| `inspector.acceptedFiles` | Принятые файлы | Панель / SuspiciousFilesBlock | — | план §3.5, L144 |
| `inspector.previouslyAcceptedFiles` | Принятые ранее | Панель / SuspiciousFilesBlock | — | план §3.5, L144 |
| `inspector.text052` | Добавить в исключения проекта… | Панель / SuspiciousFilesBlock | — | план §3.5, L145 |
| `inspector.text053` | Подозрительные файлы | Панель / SuspiciousFilesBlock | — | план §3.5, L145 |
| `inspector.text054` | Инциденты | Панель / SuspiciousFilesBlock | — | план §3.5, L146, L155 |
| `inspector.requestedModel` | Запрошена | Панель / ModelSubstitutionBlock | — | план §3.5, L147 |
| `inspector.actualModel` | Ответила | Панель / ModelSubstitutionBlock | — | план §3.5, L147 |
| `inspector.retry` | Повторить | Панель / ModelSubstitutionBlock | — | план §3.5, L147 |
| `inspector.otherModel` | Другая модель | Панель / ModelSubstitutionBlock | — | план §3.5, L147 |
| `inspector.text059` | коммит демона · из резюме стадии | Панель / TaskInspector | — | план §3.5, L148 |
| `inspector.text060` | станет сообщением коммита | Панель / TaskInspector | — | план §3.5, L148 |
| `inspector.text061` | страховочный коммит | Панель / TaskInspector | — | план §3.5, L148 |
| `inspector.text062` | последнее действие | Панель / TaskInspector | — | план §3.5, L149 |
| `inspector.text063` | Найдены подозрительные файлы: 2 | Панель / TaskInspector | числа/дата/время в примере: шаблон не задан | план §3.5, L150 |
| `inspector.text064` | Приняты вами 14:50 · <действие> | Панель / TaskInspector | действие, числа/дата/время в примере: шаблон не задан | план §3.5, L150 |
| `inspector.text065` | автозапусков 7 из 12 | Панель / TaskInspector | числа/дата/время в примере: шаблон не задан | план §3.5, L150 |
| `inspector.text066` | Замечание агенту или ответ… | Панель / TaskInspector | — | план §3.5, L151 |
| `inspector.text067` | Добавит одну попытку | Панель / TaskInspector | — | план §3.5, L151 |
| `inspector.text068` | Обнулит счётчик запусков | Панель / TaskInspector | — | план §3.5, L151 |
| `inspector.requestChanges` | Вернуть с комментарием | Панель / TaskInspector | — | план §3.5, L151 |
| `inspector.text070` | Поставьте на паузу | Панель / TaskInspector | — | план §3.5, L151 |
| `inspector.retry.variant071` | Перезапустить | Панель / TaskInspector | — | план §3.5, L153 |
| `inspector.model` | Модель | Панель / TaskInspector | — | план §3.5, L153 |
| `inspector.cancel.variant073` | Отменить | Панель / TaskInspector | — | план §3.5, L153 |
| `inspector.keepBranch` | Сохранить ветку | Панель / TaskInspector | — | план §3.5, L153 |
| `inspector.text075` | сохранится как `kaban/archive/<task-id>` | Панель / TaskInspector | task-id | план §3.5, L153 |
| `inspector.text076` | Ужесточить политику… | Панель / TaskInspector | — | план §3.5, L156 |
| `inspector.text077` | Загрузить ранее | Панель / TaskInspector | — | план §3.5, L157 |
| `inspector.text078` | Открыть сырой лог | Панель / TaskInspector | — | план §3.5, L157 |
| `gitGrant.allowOnce` | Разрешить один раз | Лента / GitDenialRow, разрешения git | — | план §3.6, L159, L164 |
| `gitGrant.text002` | Не настраивается: push делает только Kaban | Лента / GitDenialRow, разрешения git | — | план §3.6, L163 |
| `gitGrant.addToPolicy` | Добавить в политику… | Лента / GitDenialRow, разрешения git | — | план §3.6, L164, L174 |
| `gitGrant.grantPending` | Выдаём разрешение… | Лента / GitDenialRow, разрешения git | — | план §3.6, L165 |
| `gitGrant.text005` | Разрешено один раз · агент узнает при следующем вызове инструмента доски | Лента / GitDenialRow, разрешения git | — | план §3.6, L166 |
| `gitGrant.text006` | …уйдёт в промпт следующего запуска стадии Dev | Лента / GitDenialRow, разрешения git | — | план §3.6, L166 |
| `gitGrant.revoke` | Отозвать | Лента / GitDenialRow, разрешения git | — | план §3.6, L166, L167 |
| `gitGrant.text008` | Доставлено агенту 14:27 · в ответе инструмента | Лента / GitDenialRow, разрешения git | числа/дата/время в примере: шаблон не задан | план §3.6, L167 |
| `gitGrant.text009` | · в промпте run #4 | Лента / GitDenialRow, разрешения git | числа/дата/время в примере: шаблон не задан | план §3.6, L167 |
| `gitGrant.text010` | Использовано 14:41 · run #3 | Лента / GitDenialRow, разрешения git | числа/дата/время в примере: шаблон не задан | план §3.6, L168 |
| `gitGrant.text011` | Отозвано вами 14:50 | Лента / GitDenialRow, разрешения git | числа/дата/время в примере: шаблон не задан | план §3.6, L169 |
| `gitGrant.text012` | Не использовано: задача завершена / отменена | Лента / GitDenialRow, разрешения git | — | план §3.6, L170 |
| `gitGrant.text013` | создано → доставлено агенту → списано | Лента / GitDenialRow, разрешения git | — | план §3.6, L172 |
| `gitGrant.text014` | отозвано | Лента / GitDenialRow, разрешения git | — | план §3.6, L172 |
| `gitGrant.text015` | истекло | Лента / GitDenialRow, разрешения git | — | план §3.6, L172 |
| `gitGrant.retryStage` | Перезапустить стадию | Лента / GitDenialRow, разрешения git | — | план §3.6, L172 |
| `gitGrant.text017` | Проект / Стадия Dev | Лента / GitDenialRow, разрешения git | — | план §3.6, L174 |
| `gitGrant.save` | Сохранить | Лента / GitDenialRow, разрешения git | — | план §3.6, L174 |
| `gitGrant.text019` | Добавлено в политику проекта · версия abc123 | Лента / GitDenialRow, разрешения git | числа/дата/время в примере: шаблон не задан | план §3.6, L174 |
| `review.text001` | Сводка | Human Review / ReviewView | — | план §3.7, L176 |
| `review.text002` | изменено при разрешении конфликта | Human Review / ReviewView | — | план §3.7, L176 |
| `review.openInCursor` | Открыть в Cursor | Human Review / ReviewView | — | план §3.7, L176 |
| `review.approve` | Одобрить | Human Review / ReviewView | — | план §3.7, L176 |
| `review.requestChanges` | Вернуть с комментарием | Human Review / ReviewView | — | план §3.7, L176 |
| `review.text006` | Некуда вернуть: нет стадии, которая правит код | Human Review / ReviewView | — | план §3.7, L176 |
| `review.text007` | Открыть в редакторе | Human Review / ReviewView | — | план §3.7, L176 |
| `review.text008` | Куда возвращать | Human Review / ReviewView | — | план §3.7, L176 |
| `review.pipelineCannotStart` | Пайплайн не запустится | Human Review / ReviewView | — | план §3.7, L176 |
| `review.reject` | Отклонить | Human Review / ReviewView | — | план §3.7, L176 |
| `review.text011` | Отменить задачу | Human Review / ReviewView | — | план §3.7, L176 |
| `review.keepBranch` | Сохранить ветку | Human Review / ReviewView | — | план §3.7, L176 |
| `review.text013` | Вернуть в стадию ▸ | Human Review / ReviewView | — | план §3.7, L176 |
| `review.returnTarget` | Куда | Human Review / ReviewView | — | план §3.7, L176 |
| `pipeline.pipeline` | Пайплайн | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L178 |
| `pipeline.text002` | сначала перенесите N задач | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | n (N в источнике) | план §3.8, L179 |
| `pipeline.totalBounceLimit` | Общий лимит возвратов | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L182 |
| `pipeline.text004` | Лимит задач в ожидании человека | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L182 |
| `pipeline.runLimit.title` | Лимит запусков на задачу | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L182 |
| `pipeline.text006` | Лимит возвратов (у пары, например «Test → Dev») | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L183 |
| `pipeline.text007` | Лимит возвратов при красном гейте | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L183 |
| `pipeline.text008` | Лимит возвратов при конфликте | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L183 |
| `pipeline.stallTimeout` | Таймаут зависания | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L184 |
| `pipeline.wallTimeout` | Общий таймаут стадии | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L184 |
| `pipeline.retryBackoff` | Пауза перед повтором | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L184 |
| `pipeline.text012` | проверь пул | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L185 |
| `pipeline.text013` | из проекта | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text014` | Политика проекта | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text015` | Нет в пресете | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text016` | Запрещено проектом | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text017` | Переопр. | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text018` | ↺ к проекту | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text019` | Сбросить всё к проекту | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text020` | Пресет проекта: Стандартный | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text021` | Изменить в проекте | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text022` | унаследовано / переопределено | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text023` | разрешить при условии | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text024` | сужено до чтения | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186, L190 |
| `pipeline.text025` | Агент не коммитит — коммит стадии делает демон из резюме (`summary`) | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L186 |
| `pipeline.text026` | Выключен в MCP проекта — не подключится | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L187 |
| `pipeline.save` | Сохранить | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L187, L190, L191 |
| `pipeline.text028` | Открыть MCP проекта | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L187 |
| `pipeline.text029` | Проверка недоступна — нет связи с Kaban | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L190 |
| `pipeline.text030` | ошибка | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L190 |
| `pipeline.text031` | <число> с | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | число | план §3.8, L190 |
| `pipeline.text032` | <число> мин | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | число | план §3.8, L190 |
| `pipeline.text033` | <число> ч | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | число | план §3.8, L190 |
| `pipeline.text034` | Таймаут зависания должен быть от 1 мин до 30 мин | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | числа/дата/время в примере: шаблон не задан | план §3.8, L190 |
| `pipeline.text035` | Стадия «{stage}» только читает: `{cmd}` разрешить нельзя | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | stage, cmd | план §3.8, L190 |
| `pipeline.text036` | ёлочках | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L190 |
| `pipeline.text037` | вне каталога — не значит не пишет: `replace`, `gc`, `prune` | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L190 |
| `pipeline.text038` | Некуда вернуть: нет стадии, которая правит код | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L190 |
| `pipeline.text039` | Куда возвращать | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L190 |
| `pipeline.text040` | Есть незакоммиченные правки пайплайна | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L192 |
| `pipeline.text041` | Применить | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L192 |
| `pipeline.text042` | Перезагрузить / Перезаписать | Настройки пайплайна / StageEditorForm, ModelPicker, StageGitOverrides | — | план §3.8, L194 |
| `settings.save` | Сохранить | Настройки проекта / Settings | — | план §3.9, L198, L208 |
| `settings.text002` | Пресет проекта | Настройки проекта / GitPolicy | — | план §3.9, L201 |
| `settings.text003` | Стандартный | Настройки проекта / GitPolicy | — | план §3.9, L202 |
| `settings.text004` | что можно агенту | Настройки проекта / GitPolicy | — | план §3.9, L202 |
| `settings.text005` | кто коммитит | Настройки проекта / GitPolicy | — | план §3.9, L202 |
| `settings.text006` | агент только читает: `status`, `diff`, `log`, `show`; коммитит демон один раз после зелёных гейтов и проверки результата, сообщение из резюме стадии (`summary`, пустое → `kaban: <стадия> <задача>`) | Настройки проекта / GitPolicy | стадия, задача | план §3.9, L202 |
| `settings.text007` | агент + страховочный коммит демона | Настройки проекта / GitPolicy | — | план §3.9, L202 |
| `settings.text008` | из пресета / переопределено | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text009` | Без push | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text010` | Remotes не меняются | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text011` | Git config и hooks не меняются | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text012` | Теги не трогаются | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text013` | Без принудительных флагов | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text014` | `main` и чужие ветки не двигаются | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text015` | `.kaban/` только для демона | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text016` | Слияние в `main` делает только демон | Настройки проекта / GitPolicy | — | план §3.9, L203 |
| `settings.text017` | Коммитит демон из резюме | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text018` | Агент + страховочный коммит | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text019` | разрешено | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text020` | запрещено | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text021` | сужено | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text022` | унаследовано | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text023` | унаследовано / … | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text024` | из проекта | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text025` | переопределено | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text026` | сужено до чтения | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text027` | Нет в пресете (из каталога) | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text028` | Разрешено | Настройки проекта / GitPolicy | — | план §3.9, L204, L205 |
| `settings.text029` | По условию | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text030` | Запрещено | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text031` | Жёсткие | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text032` | Нет в пресете (из каталога): <команды> | Настройки проекта / GitPolicy | команды | план §3.9, L204 |
| `settings.text033` | Всё вне каталога — запрещено | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text034` | перенос чужих коммитов | Настройки проекта / GitPolicy | — | план §3.9, L204 |
| `settings.text035` | Политика проекта | Настройки проекта / GitPolicy | — | план §3.9, L205 |
| `settings.text036` | Нет в пресете | Настройки проекта / GitPolicy | — | план §3.9, L204, L205 |
| `settings.text037` | Запрещено проектом | Настройки проекта / GitPolicy | — | план §3.9, L205 |
| `settings.text038` | Переопр. | Настройки проекта / GitPolicy | — | план §3.9, L205 |
| `settings.text039` | Запрет проекта стадия не снимает · Изменить в проекте | Настройки проекта / GitPolicy | — | план §3.9, L205 |
| `settings.text040` | Максимальный размер файла, МБ | Настройки проекта / Settings | — | план §3.9, L206 |
| `settings.text041` | Добавить в исключения проекта… | Настройки проекта / Settings | — | план §3.9, L206 |
| `settings.text042` | — | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text043` | Изменить… | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.identity.name` | Имя | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.identity.email` | Почта | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text046` | с новых коммитов | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text047` | Добавить проект | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text048` | Не задан автор коммитов: укажите имя и почту | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text049` | В настройках git нашлось… | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text050` | … в настройках git содержит служебные символы, укажите вручную | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.identity.nameMissing` | Укажите имя | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.identity.emailMissing` | Укажите почту | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text053` | Имя должно быть в одну строку, без служебных символов | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text054` | Почта должна быть в одну строку, без служебных символов | Настройки проекта / GitIdentityForm | — | план §3.9, L210 |
| `settings.text055` | нужен Kaban | Настройки проекта / McpAllowlist | — | план §3.9, L211 |
| `settings.text056` | Список хранится только на этом Маке; конфиг MCP Kaban собирает сам на каждый запуск; лишний сервер в CLI — запуск не стартует | Настройки проекта / McpAllowlist | — | план §3.9, L211 |
| `settings.text057` | CLI видит сервер «<имя>» вне конфига Kaban | Настройки проекта / McpAllowlist | имя | план §3.9, L211 |
| `settings.text058` | выбран в стадиях: Dev, Test | Настройки проекта / McpAllowlist | — | план §3.9, L211 |
| `settings.cursorQuota` | Квота Cursor | Настройки проекта / Settings | — | план §3.9, L213 |
| `addProject.text001` | Создать шаблон `.kaban/` и закоммитить | Добавление / AddProjectFlow | — | план §3.10, L216 |
| `addProject.text002` | Не git-репозиторий | Добавление / AddProjectFlow | — | план §3.10, L216 |
| `addProject.text003` | Не задан автор коммитов: укажите имя и почту | Добавление / AddProjectFlow | — | план §3.10, L217 |
| `addProject.identity.name` | Имя | Добавление / AddProjectFlow | — | план §3.10, L217, L218 |
| `addProject.identity.email` | Почта | Добавление / AddProjectFlow | — | план §3.10, L217, L218 |
| `addProject.add` | Добавить | Добавление / AddProjectFlow | — | план §3.10, L217 |
| `addProject.text007` | из настроек git | Добавление / AddProjectFlow | — | план §3.10, L218 |
| `addProject.text008` | В настройках git нашлось только имя, почты нет | Добавление / AddProjectFlow | — | план §3.10, L218 |
| `addProject.text009` | В настройках git нашлась только почта, имени нет | Добавление / AddProjectFlow | — | план §3.10, L218 |
| `addProject.text010` | Имя в настройках git содержит служебные символы, укажите вручную | Добавление / AddProjectFlow | — | план §3.10, L218 |
| `addProject.text011` | Почта в настройках git содержит служебные символы, укажите вручную | Добавление / AddProjectFlow | — | план §3.10, L218 |
| `addProject.identity.nameMissing` | Укажите имя | Добавление / AddProjectFlow | — | план §3.10, L219 |
| `addProject.identity.emailMissing` | Укажите почту | Добавление / AddProjectFlow | — | план §3.10, L219 |
| `addProject.text014` | Имя должно быть в одну строку, без служебных символов | Добавление / AddProjectFlow | — | план §3.10, L219 |
| `addProject.text015` | Почта должна быть в одну строку, без служебных символов | Добавление / AddProjectFlow | — | план §3.10, L219 |
| `addProject.hideLane` | Убрать с доски | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L224 |
| `addProject.emptyBoard` | Перетащите проект сюда | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L225 |
| `addProject.text018` | Ждут человека | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L226 |
| `addProject.text019` | Инциденты | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L226 |
| `addProject.showOnBoard` | Показать на доске | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L227 |
| `addProject.hideOnBoard` | Скрыть с доски | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L227 |
| `addProject.text022` | Вид | Доска / Sidebar, LaneHeader, EmptyBoardView | — | план §3.10, L227 |
| `onboarding.text001` | Открыть Объекты входа | Онбординг / SMAppService, checkEnvironment | — | план §3.11, L230 |
| `onboarding.text002` | `cursor-agent login` в Терминале | Онбординг / SMAppService, checkEnvironment | — | план §3.11, L233 |
| `onboarding.recheck` | Проверить снова | Онбординг / SMAppService, checkEnvironment | — | план §3.11, L233 |
| `menuBar.text001` | ждёт человека | Менюбар / MenuBarExtra, уведомления | — | план §3.12, L236 |
| `menuBar.clearRateLimit` | Снять сейчас | Менюбар / MenuBarExtra, уведомления | — | план §3.12, L236 |
| `menuBar.text003` | Cursor недоступен | Менюбар / MenuBarExtra, уведомления | — | план §3.12, L236 |
| `menuBar.recheck` | Проверить снова | Менюбар / MenuBarExtra, уведомления | — | план §3.12, L236 |
| `menuBar.openBoard` | Открыть доску | Менюбар / MenuBarExtra, уведомления | — | план §3.12, L236 |
| `menuBar.answer` | Ответить | Менюбар / MenuBarExtra, уведомления | — | план §3.12, L236 |
| `menuBar.text007` | лимит Cursor, возобновление в 16:40 | Менюбар / MenuBarExtra, уведомления | числа/дата/время в примере: шаблон не задан | план §3.12, L236 |
| `quota.unofficial` | неофициально | Квота / QuotaBars, настройки Мака | — | план §3.13, L238, L242 |
| `quota.text002` | Этот Мак | Квота / QuotaBars, настройки Мака | — | план §3.13, L239 |
| `quota.text003` | сброс через 9 д | Квота / QuotaBars, настройки Мака | числа/дата/время в примере: шаблон не задан | план §3.13, L239 |
| `quota.exhausted` | исчерпан | Квота / QuotaBars, настройки Мака | — | план §3.13, L239 |
| `quota.noData` | нет данных | Квота / QuotaBars, настройки Мака | — | план §3.13, L240 |
| `quota.text006` | нет свежих данных — работает реактивная схема | Квота / QuotaBars, настройки Мака | — | план §3.13, L240 |
| `quota.cursorQuota` | Квота Cursor | Квота / QuotaBars, настройки Мака | — | план §3.13, L241 |
| `quota.text008` | модель → пул | Квота / QuotaBars, настройки Мака | — | план §3.13, L245 |
| `quota.text009` | проверь пул | Квота / QuotaBars, настройки Мака | — | план §3.13, L245 |
| `quota.refreshModels` | Обновить список | Квота / QuotaBars, настройки Мака | — | план §3.13, L245 |
| `drag.text001` | Прервать текущий запуск? Попытка не спишется | Доска / drag карточки, подтверждение | — | план §3 Drag-and-drop, L252 |
| `accessibility.text001` | SHOP-42, Dev, ждёт человека: лимит возвратов, возвраты 3 из 3 | Доступность / карточка, роторы, LaneHeader | числа/дата/время в примере: шаблон не задан | план §5, L286 |
| `accessibility.text002` | ждут человека | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `accessibility.text003` | инциденты | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `accessibility.text004` | дорожки | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `accessibility.showOnBoard` | Показать на доске | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `accessibility.hideOnBoard` | Скрыть с доски | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `accessibility.hideLane` | Убрать с доски | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `accessibility.text008` | Сдвинуть влево / вправо | Доступность / карточка, роторы, LaneHeader | — | план §5, L286 |
| `inspector.text079` | Лента | Панель / TaskInspector | — | план §3.5, L150 |
| `inspector.text080` | Живой лог | Панель / TaskInspector | — | план §3.5, L150 |
| `inspector.text081` | Сводка | Панель / TaskInspector | — | план §3.5, L150 |
| `inspector.text082` | Попытки | Панель / TaskInspector | — | план §3.5, L150 |
| `inspector.text083` | Разрешения git | Панель / TaskInspector | — | план §3.5, L150 |
| `boards.text003` | очередь / в работе агентов / ждёт человека / слияние / готово | Доска / SwimlanesView, KindGroupedBoardView | — | план §3.3, L83 |

## Ошибки валидации: все 37 кодов §4.1

Область: StageEditorForm / список ValidationIssue / ошибки пайплайна. Основание — спека §4.1 и независимая сверка AN4 ([PR #18](https://github.com/imedfan/kaban/pull/18)); это каталог, повторный аудит AN4 не проводится. Код определяет текст, `severity` определяет ошибку/предупреждение. При отсутствии хотя бы одной подстановки показывать `message` без изменений; для неизвестного кода — `message` и сам код. Предупреждения не блокируют сохранение.

`{stage}` — имя стадии по `stageId`; `{path}` — `ValidationIssue.path`; остальные — `ValidationIssue.params`. `{label}` переводится по таблице ниже (неизвестный label — как есть); длительности `{min}`/`{max}`: `1s` → «1 с», `1m` → «1 мин», `2h` → «2 ч», неизвестный формат — как есть. Диапазоны поступают от демона. `{cmd}` — первое слово правила.

| Предлагаемый ключ / код | Точный текст / ветвление источника | Подстановки | Источник |
|---|---|---|---|
| `validation.yaml_syntax` | Ошибка в YAML, строка {line} | line | спека §4.1, L504 |
| `validation.version_unsupported` | Версия пайплайна {n} не поддерживается, нужна 1 | n | спека §4.1, L505 |
| `validation.type_mismatch` | Неверный формат поля `{path}` | path | спека §4.1, L506 |
| `validation.missing_field` | Не заполнено обязательное поле `{path}` | path | спека §4.1, L507 |
| `validation.invalid_value` | Недопустимое значение `{value}` в `{path}` | path, value | спека §4.1, L508 |
| `validation.unknown_key` | Неизвестный ключ `{key}` (строка {line}), он будет проигнорирован | key, line | спека §4.1, L509 |
| `validation.no_stages` | В пайплайне нет стадий | — | спека §4.1, L510 |
| `validation.invalid_id` | Id стадии может содержать только строчные латинские буквы, цифры, «-» и «_» | — | спека §4.1, L511 |
| `validation.duplicate_id` | Стадия: «Id «{id}» уже занят другой стадией»; в `returns_to`: «Возврат в «{id}» указан дважды» (по `path`) | id | спека §4.1, L512 |
| `validation.unknown_stage` | Стадии «{id}» нет в пайплайне | id | спека §4.1, L513 |
| `validation.queue_count` | Нужна ровно одна стадия Backlog, сейчас {n} | n | спека §4.1, L514 |
| `validation.merge_count` | Нужна ровно одна стадия Merge, сейчас {n} | n | спека §4.1, L515 |
| `validation.terminal_missing` | Нет стадии Done | — | спека §4.1, L516 |
| `validation.terminal_has_on_success` | Done — последняя стадия, «Дальше» у неё не задаётся | — | спека §4.1, L517 |
| `validation.on_success_missing` | Не указано, куда задача идёт после «{stage}» | stage | спека §4.1, L518 |
| `validation.on_success_cycle` | Стадии идут по кругу: задача никогда не дойдёт до Done | — | спека §4.1, L519 |
| `validation.terminal_unreachable` | Из «{stage}» задача не дойдёт до Done | stage | спека §4.1, L520 |
| `validation.field_not_allowed_for_kind` | Поле `{field}` не используется у стадий типа {kind} | field, kind | спека §4.1, L521 |
| `validation.returns_not_allowed` | Возвраты через `returns_to` есть только у агентских стадий; у проверки — «Если не прошло», у Merge — «При конфликте» | — | спека §4.1, L522 |
| `validation.returns_forward` | Вернуть можно только на более раннюю стадию | — | спека §4.1, L523 |
| `validation.no_return_target` | Со `stageId`: Вернуть можно только на агентскую стадию, которая правит код; без: Некуда вернуть: нет стадии, которая правит код | — | спека §4.1, L524 |
| `validation.agent_missing` | У стадии «{stage}» не настроен агент | stage | спека §4.1, L525 |
| `validation.model_missing` | У стадии «{stage}» не выбрана модель | stage | спека §4.1, L526 |
| `validation.model_auto_forbidden` | Модель auto не подходит: выберите модель явно | — | спека §4.1, L527 |
| `validation.harness_unsupported` | Исполнитель `{harness}` не поддерживается | harness | спека §4.1, L528 |
| `validation.wip_out_of_range` | WIP должен быть от {min} до {max} | max, min | спека §4.1, L529 |
| `validation.limit_out_of_range` | {label} должен быть от {min} до {max}; для `max_file_mb` (нет `min`/`max`) — `message` | label, max, min | спека §4.1, L530 |
| `validation.attempts_out_of_range` | Число попыток должно быть от {min} до {max} | max, min | спека §4.1, L531 |
| `validation.duration_out_of_range` | {label} должен быть от {min} до {max} | label, max, min | спека §4.1, L532 |
| `validation.backoff_too_long` | Пауз больше, чем попыток: допустимо не больше {max} | max | спека §4.1, L533 |
| `validation.secret_in_env` | Похоже на секрет в `{key}`: не храните секреты в pipeline.yaml | key | спека §4.1, L534 |
| `validation.mcp_not_allowlisted` | MCP-сервер «{name}» выключен и в запусках будет недоступен | name | спека §4.1, L535 |
| `validation.git_hard_invariant` | Это ограничение git отключить нельзя | — | спека §4.1, L536 |
| `validation.git_condition_invalid` | Условие `{when}` не поддерживается: допустимо только `return_reason == <причина>` | when | спека §4.1, L537 |
| `validation.git_unknown_command` | Неизвестная git-команда `{cmd}` (только первое слово правила): проверьте написание | cmd | спека §4.1, L538 |
| `validation.git_readonly_extend` | Стадия «{stage}» только читает: `{cmd}` разрешить нельзя | cmd, stage | спека §4.1, L539 |
| `validation.stage_has_active_tasks` | В «{stage}» есть задачи: сначала перенесите их | stage | спека §4.1, L540 |

Для `duplicate_id` выбирать два текста по `path`; для `no_return_target` — по наличию `stageId`. Для `limit_out_of_range` у `max_file_mb` использовать `message`: у этой ветки нет `min`/`max`. Эти ветви не надо склеивать в одну строку UI.

| Предлагаемый ключ | Точная подпись `{label}` | YAML / источник |
|---|---|---|
| `pipeline.label.bounce_limit_total` | Общий лимит возвратов | `bounce_limit_total`, спека §4.1, L546 |
| `pipeline.label.returns_to.limit` | Лимит возвратов (у пары, например «Test → Dev») | `returns_to.limit`, спека §4.1, L547 |
| `pipeline.label.on_fail.limit` | Лимит возвратов при красном гейте | `on_fail.limit`, спека §4.1, L548 |
| `pipeline.label.on_conflict.limit` | Лимит возвратов при конфликте | `on_conflict.limit`, спека §4.1, L549 |
| `pipeline.label.max_waiting_human` | Лимит задач в ожидании человека | `max_waiting_human`, спека §4.1, L550 |
| `pipeline.label.max_runs_per_task` | Лимит запусков на задачу | `max_runs_per_task`, спека §4.1, L551 |
| `pipeline.label.max_file_mb` | Максимальный размер файла, МБ | `max_file_mb`, спека §4.1, L552 |
| `pipeline.label.stall` | Таймаут зависания | `stall`, спека §4.1, L553 |
| `pipeline.label.wall` | Общий таймаут стадии | `wall`, спека §4.1, L554 |
| `pipeline.label.backoff` | Пауза перед повтором | `backoff`, спека §4.1, L555 |

## Повторы и расхождения

- «Проверить снова», «Сохранить», «Открыть в Cursor», «В Backlog», «Отменить…», «Сохранить ветку» повторяются в нескольких компонентах. Ключи пока локальны экрану; общий ключ возможен только после проверки смысла и контекста, особенно где сохранение означает разную команду.
- «Лимит возвратов» повторяется как подпись пары, заголовок причины и текст листа. Не объединять заголовок, уточнение и общий счётчик: спека §1.3 и план §3.4/§3.5/§3.8 намеренно различают «Общий лимит возвратов», «Всего возвратов N/5» и уточнения.
- План §3.5 содержит **«Принятые файлы»**, затем явно называет вариант макета **«Принятые ранее»**. Оба являются цитатами плана; подтвердить одну подпись предстоит владельцу продукта. Сам макет не проверялся.
- План §3.5: **«В исключения проекта…»** (строка таблицы) и **«Добавить в исключения проекта…»** (ссылка/описание перехода); спека UC-25: **«Добавить в исключения проекта…»**. Нужна договорённость, допустима ли короткая подпись внутри таблицы.
- План §3.4/§3.5: **«Вернуть с замечанием»**; §3.7: **«Вернуть с комментарием»**. Команды и контекст различаются (возврат подозрительных файлов и Human Review); не считать автоматически ошибкой. Спека UC-25 использует «Вернуть с замечанием».
- План §3.1: **«Лимит Cursor, возобновление в 16:40»**; §3.12 и спека UC-09: **«лимит Cursor, возобновление в 16:40»**. Разница — регистр первого слова; установить единый текст для баннера/уведомления либо явно оставить отдельные ключи.
- План §3.1 содержит пример **«Пайплайн не запустится: нет модели у Dev, Test»**, спека UC-23 — **«Пайплайн не запустится: нет модели у Test»**. Отличается состав стадий, это динамический пример, не разный диагноз; формат списка не определён отдельным шаблоном.
- Подписи `{label}` плана §3.8 совпадают со свежей спекой §4.1. Валидационные тексты брать из §4.1, а не из сокращённого пересказа плана.
- В плане §3.8 упомянутые **«Переключить на Auto»** и в §3.10 **«Один / Несколько / Все»** отсутствуют в UI по прямому запрету источника. Они не входят в каталог активных строк.

## Итог и открытые вопросы

Все 13 экранных разделов §3, drag-and-drop и §5 представлены: 377 точных фрагментов плана, 37 validationCodes, 10 подписей label, 10 явно отмеченных пробелов «нет текста». Источники есть у каждой записи; строк без источника не добавлено. Фразы в таблице — исходные цитаты, включая примеры/варианты: перед реализацией нужно согласовать шаблоны динамических значений и окончательные смысловые ключи.

Не выполнено: план ↔ макет (исключено человеком), runtime/VoiceOver-проверка (SwiftUI-клиент ещё не реализован), утверждение отсутствующих подписей. Вопросы владельцам Frontend/Analyst: полные тексты согласия квоты и тостов команд, отдельные варианты сокращённых фраз с `/`, подпись истории принятых файлов. Известные пробелы TaskDetail (#14) и спецификации (#9/#10/#11) здесь не дублируются как новые баги. Уверенность высокая для точности цитат/37 кодов, средняя для будущего разделения ключей.
