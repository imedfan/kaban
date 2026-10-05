# Backend: durable команды интерфейса

База: `origin/main` `92e3d73` после принятого UI PR #67. Рабочая ветка:
`codex/backend-wire-commands`. Этот инкремент закрывает первый пункт
[backend-плана](../backend-plan-v0.md); приложение пока использует mock.

## План и граница

1. Обработчик существующего `CommandEnvelope` в DaemonCore: create/edit/priority,
   move/pause/resume/cancel/retry, ответы и решения Human Review, чтение деталей.
2. Durable настройки: ручные паузы Мака/проекта, глобальный потолок runs,
   quota options и metadata зарегистрированного проекта.
3. Новая additive миграция, оригинальный запрос и wire receipt. Сверка повтора
   происходит до генерации task ID/time. Успех и доменный отказ воспроизводятся
   после reopen; сбой БД откатывает всю команду и допускает повтор.
4. Проверка journal/projection, stale effects, WIP/admission, rollback и повтора
   через существующие frontend DTO. Полный сценарный прогон и ревью diff.

Регистрация проекта остаётся внутренним bounded fake API. Неподдержанные
команды получают явный отказ. XPC, реальный git/Cursor, pipeline replacement,
MCP, квота по сети и установка LaunchAgent следуют отдельными инкрементами.
Сохранение quota options не означает работу quota poller.

## Семантика

- Результат команды не заменяет journal event. Все успешные mutation-команды,
  включая повторную установку значения, публикуют correlated событие.
- `body` сохраняется буквально. Наличие критериев определяется по разделу,
  который формирует текущий frontend: `\n\n## Критерии приёмки\n` и непустой текст
  после него. Описание само по себе не является критериями.
- Edit разрешён в queued/waiting_human/paused. Отсутствующее body не превращается
  в пустое. Чтения возвращают текущий seq и не фиксируют устаревающий query reply.
- Ручные паузы блокируют новый admission/execution; доставка результата уже
  запущенного run остаётся разрешённой. Флаги и StageLoad авторитетны у store.
- `SettingsChange.schedulerFlags` — совместимое optional поле полного набора
  флагов в durable событии; nil означает старое/неизвестное значение, `[]` снимает
  флаги. Live ephemeral DTO остаётся прежним. Query replies свежие и не занимают
  commandId; protocol mismatch и конфликт ID не заменяют исходный receipt.
- Quota options требуют consent при enabled и положительный интервал; пороги
  конечны и лежат в 0…100. При явном первом согласии сохраняется время команды,
  повтор не обновляет его. Неизвестные начальные настройки не угадываются.
- Перенос назад прерывает run и supersedes старые execution effects. Human
  admission освобождается при выходе из стадии. Перенос из Backlog в первую
  стадию требует критериев и доступного слота.
- В architecture §3.3 строка moveTask говорит «в любую стадию», а UC-11 и
  DropRules запрещают перенос вперёд. Wire-приёмник применяет конкретное
  ограничение UC-11; общий reducer остаётся внутренним механизмом перехода.

## Следующие инкременты

1. Daemon host и XPC/kabanctl: snapshot/subscription handshake, catch-up,
   reconnect/resync и повтор исходного envelope. Затем подключение BoardStore.
2. Production project/pipeline lifecycle и внешний executor с claim/lease,
   git-клонами, Cursor/gates, recovery и durable effect receipts.
3. MCP/git shim, incident/files lifecycle, catalog/quota и isolation-спайки.
4. Полная M1/MVP-приёмка, упаковка и подпись.

## Проверки

На diff этого инкремента:

| Проверка | Результат |
|---|---|
| `KABAN_SCENARIOS=Scenarios/M1 swift test` | 315 tests, 0 failures, 0 skips: Protocol 55, Kit 159, DaemonCore 35, BoardCore 66 |
| Новая командная поверхность | 17 wire tests: reopen/replay/conflict, concurrent connections, rollback после projection/outbox, V2 upgrade, human admission, pause/current runs, priority/FIFO, snapshot+journal |
| Wire compatibility | 3 tests legacy SettingsChange/explicit empty/null/malformed flags, существующие golden/legacy fixtures без правок |
| Retry capacity | Отказ Int.max без состояния/effects; максимальный представимый budget допускается |
| Kaban.app unsigned xcodebuild | BUILD SUCCEEDED, `/tmp/kaban-context-app` |
| Штатный `--ui-smoke` | Passed: настоящий WindowGroup, create/edit/move/cancel, pause/resume, Markdown, search/filter, Cmd-N/Cmd-F |
| `python3 tools/check-project-context.py`, `git diff --check` | Passed |

Первый полный прогон в sandbox дал 6 assertions из-за предупреждения системного
git о недоступном `DARWIN_USER_TEMP_DIR`; Xcode не мог скачать GRDB из-за
запрета сети. Повтор обычного swift test и xcodebuild вне sandbox успешен.
Assertions и фикстуры ради среды не ослаблялись.

Статическое ревью по diff-impact-reviewer-global охватило исходный запрос/receipts,
savepoint и outer transaction, shared ID namespace, v1/v2 migration, scheduler,
effect superseding, detail/run summaries, Protocol и BoardProjection. Блокеров
и критичных security проблем не найдено: SQL параметризован, wire-инкремент
не исполняет пути/команды/git и не получает токены.

Linux CI в этой локальной проверке не запускался. UI smoke продолжает использовать
mock; он не подтверждает связь с backend. Светлая/тёмная темы, минимальный размер,
длинный текст и VoiceOver повторно визуально не принимались: views не менялись.
XPC/reconnect/resync и реальные процессы остаются следующим результатом.
