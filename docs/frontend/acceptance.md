# Kaban: Юзеркейсы, доступность и производительность

Требования выделены из frontend-plan v0.5.37 без изменения поведения.
Статус реализации — [current-state](../current-state.md); порядок работы — [frontend-plan](../frontend-plan-v0.md).
Имена DTO и команд сверять с `Sources/KabanProtocol/`; числовые ссылки 3.x сохранены из исходного плана.
Предложения фронта остаются предложениями. Макеты и токены — [design](../../design/README.md).

## 4. Юзеркейсы v0.8.22 → экраны и компоненты

| UC | Экраны | Компоненты и команды |
|---|---|---|
| UC-01 Подключить проект | Онбординг, добавление | `AddProjectFlow`: `addProject(path, createTemplate, identity?)` (`identity_required` → поля «Имя» и «Почта» в листе, 3.10), `setProjectIdentity` в настройках (3.9), `listBranches`, `detectGates`, `checkEnvironment`; новый проект сразу на доске (`BoardSetStore`); без шаблона — `unavailable: no_pipeline` в `LaneHeader`; Cursor не готов — баннер UC-20 |
| UC-02 Завести задачу | Доска, панель | `TaskEditorSheet` (⌘N, `createTask`); `editTask` только в `queued`/`waiting_human`/`paused`; без критериев старт выключен |
| UC-03 Автозапуск | Доска | событие → `running`, маскот `.pulse`, слоты в «Этот Мак»; если старта нет — причина видна флагом в баннере или `LaneHeader`, карточка `queued` («Ждёт места» / «Ждёт процесс») |
| UC-04 Пройти стадию | Доска, Лента, Лог | `report_progress` — «последнее действие» на карточке и лента; `complete_stage` — резюме в «Сводке»; `gating`, `retry_wait` (тот же клон после `gate_failed` / `no_final_call`), `invalid_result`, `model_unconfirmed` |
| UC-05 Возврат от тестера | Карточка, Лента | `return_to_stage`: бейдж «↩ 1/3», список замечаний в ленте; счётчик попыток стадии обнуляется; лимит → `bounce_limit` + `retryStage(grantAttempts)` |
| UC-06 Агент просит человека | Панель, уведомление, менюбар | `HumanQuestionView` → `answerHuman(taskId, text, requestId)`; «Замечание агенту» (F23) из любого `waiting_human` в `agent`-стадии → `answerHuman(taskId, text)` (на `human` / `gate` / `merge` — `invalid_state`, поля нет; арх. v0.11.21); баннер `max_waiting_human` в `LaneHeader` |
| UC-07 Ревью человеком | Human Review, уведомление | `ReviewView`: `approve`, `requestChanges(target)`, `reject(target, keepBranch)` с «Сохранить ветку», «Открыть в Cursor»; уведомление о ревью включено по умолчанию |
| UC-08 Слияние и конфликт | Доска, Human Review | «Rebase + гейты», бейдж конфликта, `conflict_limit`, пересечения, чип «после конфликта»; голова очереди `blocked: main_dirty` + флаг `merge_blocked` в `LaneHeader` |
| UC-09 Лимиты Cursor | Баннеры над доской, менюбар, «Этот Мак», уведомление | короткий `rate_limited` с `resumeAfterRateLimit`; `usage_exhausted` по пулу (`PoolBanner` и метки столбцов) или на весь Мак при `unknown`; `model_flag · unavailable` по модели; карточки `retry_wait: rate_limit`; ожидание квоты пула — серая причина у `queued`; полосы Cm/Om при включённой опции (3.13) |
| UC-10 Сбой агента | Карточка, панель | `retry_wait` с отсчётом (попытки в пределах захода) → `retries_exhausted`; `refs/kaban/wip/<run-id>` в «Попытках»; `run_limit` при 12 автозапусках; `retryStage`, «Замечание агенту» (+1 попытка), `setModelOverride`, `moveTask`, `cancelTask` |
| UC-11 Ручное управление | Доска, меню, тулбар | `pauseTask` / `resumeTask`, `pauseProject`, `pauseAll`, drag → `moveTask`, `cancelTask(keepBranch)`, `setPriority` |
| UC-12 Перезапуск демона / Мака | Вся доска | `ConnectionStore`: `subscribe(fromSeq)`, `resyncRequired` → `getSnapshot` + `getTaskDetail`; `retry_wait: daemon_restart` |
| UC-13 Изменить пайплайн | Настройки пайплайна | обязательный `ModelPicker` без Auto, «Сохранить» выключена при ошибках, `validatePipeline`, `updatePipeline` как вторая проверка, подсветка `ValidationIssue.path`, плашка «нет модели у <стадии>», «Применить» ручную правку, WIP «4/3», запрет удаления непустой стадии |
| UC-14 Несколько проектов | Сайдбар, «Этот Мак», `LaneHeader`, настройки проекта | `setProjectWeight`; флаг `unavailable` (`project_missing` → `relinkProject` / `removeProject`, `pipeline_invalid` → ошибки и настройки), `recheck(.project)` |
| UC-15 Какие проекты показывать | Сайдбар, доска, шапка дорожки, компактный вид | `BoardSetStore`; перетаскивание проекта из сайдбара (`ProjectDragItem`, зоны и индикатор вставки), крестик «Убрать с доски», «Перетащите проект сюда», «Показать на доске» / «Скрыть с доски» в меню; ⌘1–⌘9 к дорожке, ⌘⌥←/→ порядок; `SwimlanesView`, `KindGroupedBoardView` (+ «ждёт человека» для любой стадии); значки скрытых проектов в сайдбаре |
| UC-16 Маскот | Сайдбар, шапка дорожки, карточка | `MascotView`, `MascotPicker` → `setMascot`, фактура края |
| UC-17 Запрещённая git-команда | Лента, «Разрешения git», карточка, Git | `GitDenialRow` (цепочка 3.6, `gitGrantDelivered`), `allowGitOnce`, `revokeGitGrant`, `addDenialToPolicy(scope)`, бейдж ключа, `git_denials` |
| UC-18 Инцидент | Карточка, Лента, «Инциденты», уведомление, маскот | красная карточка, `IncidentRow`, `IncidentsView` со счётчиком неразобранных (F22), `.timeSensitive`, тревога маскота; действие человека разбирает инцидент |
| UC-19 Настроить git-политику | Настройки проекта → Git, редактор стадии, «Сводка» | `GitPresetPicker` на проект (Строгий / Стандартный / Свободный), `GitCommandTable` с «из пресета / переопределено», `StageGitOverrides` без своего пресета, `EffectivePolicyView`, замки; «Строгий» — коммит демона из `summary` в «Сводке»; `updatePipeline`, `gitPolicyUpdated` |
| UC-20 Cursor недоступен | Баннер над доской, менюбар, уведомление, онбординг | `SchedulerBanner` с причиной `runner_unavailable`, «Проверить снова» → `recheck(.runner)`; карточки `retry_wait: runner_auth` без списания попытки |
| UC-21 Проверка квоты (опция) | Менюбар, «Этот Мак», настройки Мака | `QuotaBars` Cm/Om, экран «Квота Cursor», таблица «модель → пул» |
| UC-22 Cursor подменил модель | Карточка, панель, баннер модели | «Подмена: A → B», `ModelSubstitutionBlock`, `ModelBanner` «Cursor подменяет <модель> · N стадий», «Повторить» / «Другая модель» / «В Backlog» |
| UC-23 Стадия без модели | `LaneHeader`, шапки столбцов, редактор | плашка «Пайплайн не запустится: нет модели у <стадии>», «Указать модели», `ModelPicker`, «Сохранить» неактивна |
| UC-24 Настроить MCP | Настройки проекта → MCP (на этом Маке), редактор стадии, `LaneHeader` | белый список серверов проекта в локальной базе, сервер доски всегда включён, `StageMcpPicker` только из белого списка, предупреждение (не ошибка) о выбранном, но выключенном в проекте сервере, `mcp_unexpected` |
| UC-25 Подозрительные файлы | Карточка, панель, Лента, уведомление, настройки проекта | `waiting_human: suspicious_files` янтарным, `SuspiciousFilesBlock` (таблица из `TaskCard.suspiciousFiles`, «Принять файлы» → `acceptSuspiciousFiles` с обработкой `stale_suspicious_files`, «Попросить убрать» → `answerHuman` без принятия, «Вернуть с замечанием» (`requestChanges` с текстом, только `gate` / `merge`) без принятия, `retryStage` / `moveTask` (в том числе «Вернуть…» → «Принять файлы и вернуть» на gate / merge) / `cancelTask` с галочкой архива ветки — с принятием, «Отклонить» только в Human Review, пометки «по шаблону» / «больше 5 МБ», «дифф» при `isText` и размере меньше `max_file_mb` через `TaskDetail.clonePath`, иначе «Показать в Finder», история `TaskDetail.acceptedFiles`), `SuspiciousFilesRow` и уведомление по `suspiciousFilesFound` / `suspiciousFilesAccepted`, состояние карточки — по `taskUpdated`, «Добавить в исключения проекта…» → `suspicious_files.allow` |

## 5. Доступность и производительность

- VoiceOver: карточка — один элемент («SHOP-42, Dev, ждёт человека: лимит возвратов, возвраты 3 из 3») с `accessibilityActions`; роторы «ждут человека», «инциденты» и «дорожки»; у проекта в сайдбаре действия «Показать на доске» / «Скрыть с доски», у `LaneHeader` — «Убрать с доски», «Сдвинуть влево / вправо»; объявления только о `waiting_human` и инцидентах.
- Клавиатура: ⌘1–⌘9 — фокус на N-й дорожке, ⌘⌥← / ⌘⌥→ — сдвиг дорожки в фокусе; фокус на карточках, стрелки, пробел открывает панель, ⌘↩ одобрить, ⌘F поиск в логе.
- Статус никогда не передаётся только цветом: значок + текст + фактура проекта. Контраст по токенам в обеих темах.
- Reduce Motion: маскоты и полосы прогресса статичны. Reduce Transparency и Increase Contrast — проверить, как деградирует `glassEffect`.
- Производительность (цель **(предложение фронта)**: 10 проектов × 500 задач, 60 fps на `mbp`): `Lazy*`-стеки, отдельные `TaskModel`, `Equatable`-карточки, события ≤ 30 Гц; glass только на шапках; анимированных маскотов не больше числа проектов; лог батчами с лимитом строк; `os_signpost` на применение событий.
