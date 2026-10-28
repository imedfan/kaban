# BE-22: результаты двух живых запусков

28 октября 2026, macOS 27.0.1, CLI `2026.09.23-86fc751`.
Артём выполнил оба платных запуска в Terminal. Бюджет исчерпан: **2/2**.
Модель обоих argv — `cursor-grok-4.6-medium`, подтверждённая бесплатным каталогом
как `Grok 4.6 Medium`. Логин выполнен самим Артёмом; учётные данные в fixtures
не сохранялись. Системные запросы macOS Артём отдельно не описал.

## Наблюдения

| Пункт BE-22 | Результат | Доказательство |
|---|---|---|
| Флаги headless/write/MCP | Подтверждена комбинация `-p --output-format stream-json --model cursor-grok-4.6-medium --force --trust --approve-mcps` | [argv](run-1/argv.json), [stream](run-1/stream.jsonl) |
| Exit первого запуска | Подтверждён exit 0; stderr пуст | [process](run-1/process.json), [stderr](run-1/stderr.txt) |
| system/init | Подтверждено отображаемое `model="Grok 4.6 Medium"`, `apiKeySource="login"`, `permissionMode="default"`; отдельного model id в init нет | [stream](run-1/stream.jsonl), [summary](run-1/summary.json) |
| MCP-конфиг клона и env | Подтверждены initialize, tools/list, report_progress и complete_stage через HTTP; auth всех запросов = match | [конфиг](run-1/mcp-config.json), [HTTP-журнал](run-1/mcp.jsonl) |
| Запись файла и shell под --force | Подтверждено: `hello.txt = "hello kaban\n"`, `shell.txt = "shell-ok"` | editToolCall/shellToolCall в [stream](run-1/stream.jsonl); файлы прочитаны из временного клона после запуска |
| Финальный MCP и result | Подтверждено: complete_stage получил `BE22-ACK`, затем `result/success`, `is_error=false` | [HTTP-журнал](run-1/mcp.jsonl), [summary](run-1/summary.json) |
| session_id / --resume в -p | Подтверждено: второй init содержит ту же сессию и ту же модель, что первый | [argv-2](run-2/argv.json), [stream-2](run-2/stream.jsonl) |
| Kill по init | Подтверждено в одном опыте: SIGTERM, returncode -15; tool_call в потоке нет, MCP tools/call нет, result не успел появиться | [process-2](run-2/process.json), [stream-2](run-2/stream.jsonl), [HTTP-2](run-2/mcp.jsonl) |
| Usage | Подтверждены inputTokens=7756, outputTokens=696, cacheReadTokens=40064, cacheWriteTokens=0 в первом result | [summary](run-1/summary.json) |
| Стоимость | Не подтверждена: поля cost/currency в result отсутствуют; это неизвестное значение, не нулевая цена | [summary](run-1/summary.json) |
| Каталог и status | Подтверждены бесплатными проверками, включая положительный login | [бесплатные факты](free-keychain-home/facts.json), [каталог](free-keychain-home/run-home/models.stdout) |
| Ошибка авторизации | Подтверждено поведение пустого HOME: isAuthenticated=false, каталог exit 1 с ошибкой входа; это бесплатная проба, не платный failure stream | [status](free/run-home/status.stdout), [ошибка](free/run-home/models.stderr), [home-auth](environment/home-auth.json) |
| mcp list | Подтверждён формат одной строки `kaban-board: not loaded (needs approval)`, exit 0 до каждого запуска | [list-1](run-1/mcp-list-before.stdout), [list-2](run-2/mcp-list-before.stdout) |
| Отдельный HOME | Иначе: пустой HOME теряет login, со ссылкой Library/Keychains — работает | [home-auth](environment/home-auth.json), [setup](environment/keychain-home.json) |
| launchd с минимальным PATH | Подтверждены бесплатные status/catalog/mcp list для обычного и подготовленного HOME; установленный helper не проверялся | [launchd](launchd-keychain-home/facts.json) |
| Каталоги записи | Подтверждены только сохранившиеся изменения в перечисленных корнях, см. ниже | [снимок-1](run-1/filesystem-changes.json), [снимок-2](run-2/filesystem-changes.json) |

## Поток: передача BE-24/25/26

Первый поток: 61 JSON-событие, ни одной невалидной строки. Помимо init/user/
assistant/tool_call/result присутствуют **thinking/delta** (40) и
**thinking/completed** (4), хотя справочный текст Cursor описывал подавление
thinking в print mode. Парсер не должен считать эти типы ошибкой.

`tool_call` содержит payload (`mcpToolCall`, `shellToolCall`, `editToolCall`,
`globToolCall`, `getMcpToolsToolCall`) **рядом** с `hookAdditionalContexts`,
`toolCallId`, `startedAtMs`, `completedAtMs`. Выбор первого ключа по алфавиту
ошибочен: он теряет реальный инструмент. Исправлен только исследовательский
summary-helper и добавлен тест по живой fixture; production parser/classifier
остаются задачей BE-25. `call_id` может содержать перевод строки внутри JSON-строки.
Usage приходит в camelCase; request_id есть, model id — только в argv/каталоге.

**Конкретное расхождение текущего production-кода:**
`Sources/KabanKit/Agent/CursorStream.swift`, `toolEvent`, тоже выбирает
`payload.keys.sorted().first`. В живом shell/MCP started вместо инструмента
получится `hookAdditionalContexts`, а в completed — `completedAtMs`, потеряется
payload результата. BE-25 должна исправить выбор payload и покрыть это потоком
из run-1; success по пустому body нельзя принимать за проверку реального результата.

MCP-заглушка предоставляет report_progress/complete_stage и отвечает
Streamable HTTP. Клиент предложил protocolVersion `2025-11-25`, сервер выбрал
`2025-06-18`; клиент использовал session header и успешно вызвал инструменты.
GET SSE получил 405; POST продолжил работать. Подстановка
`${env:KABAN_RUN_TOKEN}` в Authorization подтверждена совпадением Bearer на сервере.
Это не приёмка всей production-доски или installed helper.

Второй поток содержит только init и user. MCP initialize/initialized/GET
успели выполниться **до остановки**, но tools/call не было. Это положительный
наблюдаемый опыт остановки до инструмента, а не доказательство отсутствия гонки
между init и tool во всех запусках. Kill запускается после чтения init из pipe;
уже начавшийся внешний эффект невозможно отменить одним разбором stdout.

`--resume` подтвердил выбор сохранённой сессии и повторный init. Продолжение
ответа после resume намеренно прервано; проверка памяти диалога не проводилась.
Отдельная необходимость `--trust`, `--approve-mcps` и поведение без `--force` не
изолировались: подтверждена комбинация флагов, а не каждый фактор по отдельности.

## Каталоги: передача BE-28

Наблюдатель — сравнение `lstat` до/после, без чтения файлов. В первом опыте
1511 изменённых записей, ошибок обхода нет. Список всех путей сохранён в JSON;
минимальные наблюдаемые области:

- HOME run: `.cursor/agent-cli-state.json`, `cli-config.json`, `statsig-cache.json`;
  `.cursor/chats/` (сессия), `projects/` (trust, MCP approvals/auth, worker log/socket,
  transcripts), `ai-tracking/` (SQLite), `managed/`, `plugins/cache/`, `skills-cursor/`.
- HOME run: `Library/Caches/cursor-compile-cache/`.
- HOME run: `.local/bin/`, `.local/share/cursor-agent/versions/` — во время run
  появились файлы **автообновления** `2026.10.22-27dcf5f`. Это фоновая запись,
  не смена исследованного executable: оба argv и preflight версии ссылаются
  на исходный `/Users/artem/.local/bin/cursor-agent` версии `2026.09.23-86fc751`.
  Версии дочерних компонентов файловым снимком не установлены.
- Отдельный TMPDIR: `cursor-agent-logs-501/` (session/latest/oom).
- Клон: hello.txt и shell.txt.
- Реальный HOME: `.local/share/cursor-agent/versions/2026.09.23-86fc751/.running/`.
  Записи в реальном HOME требуют проверки атрибуции; там могли работать другие процессы.

Пустой HOME не означает отсутствия служебных assets: во время запуска CLI
создал managed/plugins/skills и загрузил обновление. Для BE-24/26 важно
повторно сверять фактический набор доступных MCP в том же окружении;
наличие пустого HOME само по себе не заменяет fail closed.

**Ограничение:** fs_usage не прошёл бесплатную проверку контрольного процесса
(exit 0, ноль событий). Снимки не видят запись за пределами перечисленных корней,
краткоживущие файлы или содержимое/изменения Keychain через symlink. Этот список
нельзя объявлять полной Seatbelt allowlist. Полное наблюдение до приёмки BE-28
и сборки/сеть/изоляция токена BE-29 остаются открытыми.

## Непроверенное и статус

**Не проверено (бюджет):** rate limit, usage/spendLimitHit, resource_exhausted,
молчаливый выход, живая подмена модели/fallbackModel, read-only/deny под --force.
Для BE-25 остаются синтетические fixtures, явно отличимые от двух живых потоков.
Квота вне MVP. Платных повторов и третьего запуска не было.

BE-22 дала живые fixtures, точную модель, auth/launchd/MCP/resume факты и
минимальные пути записи. Полная filesystem-приёмка ещё открыта из-за границы
наблюдателя; production схема HOME/Keychain требует решения в BE-24/28.
Тесты production stream/limit classifier на этих fixtures — BE-25.
Рабочий MVP и live-приёмка остальных инкрементов этим не закрываются.
