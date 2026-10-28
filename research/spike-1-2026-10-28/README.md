# BE-22: живой Cursor CLI, 28 октября 2026

База — `origin/main e5f6732`, ветка `codex/be-22-cursor-adapter`.
macOS 27.0.1, Cursor Agent `2026.09.23-86fc751`.
Бесплатные результаты получены на настоящем CLI вне sandbox Codex;
он ошибочно сообщал об отсутствии входа внутри sandbox.
Production-драйвер здесь не меняется (это BE-24/25).

**Платная часть проведена Артёмом, 2/2 старта использованы.**
См. [результаты и передачу BE-24/25/26/28](RESULTS.md).
Команды ниже сохранены для воспроизводимости; в текущем рабочем каталоге
новый платный запуск запрещён, новый каталог не даёт нового бюджета.

## Что уже подтверждено

| Проверка | Результат | Фикстура |
|---|---|---|
| Версия и флаги | `-p`, `--output-format stream-json`, `--model`, `--force`, `--trust`, `--approve-mcps`, `--resume` есть в установленном help; выполнение исследуется отдельно | [version](environment/version.stdout), [help](environment/help.stdout) |
| Вход без модели | `status --format json`, exit 0, `isAuthenticated=true` при обычном HOME | [status](free/user-home/status.stdout) |
| Точный id согласованной модели | `cursor-grok-4.6-medium - Grok 4.6 Medium`, exit 0; Auto и Fast не используются | [каталог](free/user-home/models.stdout) |
| Пустой HOME | Вход потерян, каталог недоступен | [facts](free/facts.json), [ошибка каталога](free/run-home/models.stderr) |
| Конфиг MCP клона | Видно ровно `kaban-board: not loaded (needs approval)`; это обнаружение, ещё не HTTP-вызов | [mcp list](free/run-home/mcp-list.stdout), [конфиг](free/mcp-config.json) |
| Бесплатные команды из launchd с минимальным PATH | Обычный HOME авторизован; пустой HOME — нет; модель видна в обычном HOME | [launchd facts](launchd/facts.json) |
| HOME со ссылкой `Library/Keychains` | Авторизация и каталог работают; личный `.cursor` не копируется | [setup](environment/keychain-home.json), [facts](free-keychain-home/facts.json) |
| Тот же вариант из launchd | Авторизация и модель подтверждены для HOME run | [launchd facts](launchd-keychain-home/facts.json) |

`status` содержит сведения об аккаунте, поэтому в evidence сохраняются только
булевы поля авторизации. Токены не читаются исполнителем, не копируются и не
включаются в argv. Токен тестового MCP создаётся в памяти; конфиг содержит
только `${env:KABAN_RUN_TOKEN}`. До записи вывод маскируется.

Дополнительные бесплатные опыты и сообщение Артёма записаны в
[home-auth.json](environment/home-auth.json). В пустом HOME `security list-keychains
-d user` возвращает пустой список, в обычном HOME — путь к login keychain.
Повторный login в пустом HOME завершился ошибкой Keychain 154. Удаление
`cursor-access-token`, предложенное самим CLI, не выполнялось; обычный вход
после ошибки повторно подтверждён. `CURSOR_CONFIG_DIR`, `XDG_CONFIG_HOME`,
`CFFIXED_USER_HOME` и ссылка только на `com.apple.security.plist` вход не вернули.
Одна ссылка на `Library/Keychains` вернула его без нового login.

Это исследовательский вариант, а не утверждённая схема production HOME.
Он предоставляет CLI доступ к существующей Keychain и не защищает токен от
его инструментов. BE-24/28 должны учитывать этот результат; принятый риск
архитектуры §13 и отдельная BE-29 сохраняются.

## Команды Артёму

Платные команды по PRE-01 выполняет сам Артём в Terminal.app.
Рабочий каталог `/private/tmp/kaban-be22-2026-10-28` уже подготовлен.
Его `state.json`, HOME и клон не добавляются в Git; не пересоздавайте каталог
между запусками: в нём хранится счётчик бюджета и сессия.

Подготовка для повторения на другой дате (бесплатно; нужен новый `--work`):

```sh
python3 spikes/backend/be22.py prepare --work /tmp/kaban-be22-YYYY-MM-DD --evidence research/spike-1-YYYY-MM-DD
python3 spikes/backend/be22.py free --work /tmp/kaban-be22-YYYY-MM-DD
python3 spikes/backend/be22.py launchd --work /tmp/kaban-be22-YYYY-MM-DD
python3 spikes/backend/be22.py keychain-home --work /tmp/kaban-be22-YYYY-MM-DD
python3 spikes/backend/be22.py free --work /tmp/kaban-be22-YYYY-MM-DD
python3 spikes/backend/be22.py launchd --work /tmp/kaban-be22-YYYY-MM-DD
```

Скрипт не выполняет login/logout и не меняет настройки обычного HOME.
Временный LaunchAgent с уникальным label загружается из `--work`, затем
выгружается в `finally`; в `~/Library/LaunchAgents` ничего не устанавливается.
При системном запросе доступа одобрение выполняет Артём; текст запроса
нужно записать в отчёт. Если доступ отклонён, остановиться и прислать ошибку.
Подпись App, установленный helper и reboot эта проверка не подтверждает.

**Запуск 1.** Скопировать следующую команду одной строкой:

```sh
cd /Users/artem/Documents/dev/kaban && python3 spikes/backend/be22.py trace-test --work /tmp/kaban-be22-2026-10-28 && python3 spikes/backend/be22.py paid --work /tmp/kaban-be22-2026-10-28 --kind normal
```

Все процессы работают от пользователя. `trace-test` запускает синтетический
Python-процесс, создаёт контрольный файл и проверяет снимок изменений. Это бесплатно.
Если наблюдатель не проверен, `&&` не допускает платную команду.

Перед моделью ещё раз бесплатно проверяются версия, вход, точная модель и
`mcp list` **в том же окружении с тем же MCP endpoint**. Убедиться, что в
списке ровно `kaban-board`, затем ввести `ONLY kaban-board`. При другом сервере
или нечитаемом результате — Ctrl-C, прислать вывод, не подтверждать.
После этого идёт один `-p --output-format stream-json --model
cursor-grok-4.6-medium --force --trust --approve-mcps` с фиксированным промптом:
report_progress, запись hello.txt, shell-команда, complete_stage.

В конце прислать строку `Captured run-1` либо ошибку и сообщить, какие
системные запросы появлялись. Фикстуры доступны исполнителю локально.
Не присылать HOME, state.json, данные Keychain или архив всего `--work`.

**Запуск 2.** Только после анализа первого результата:

```sh
cd /Users/artem/Documents/dev/kaban && python3 spikes/backend/be22.py paid --work /tmp/kaban-be22-2026-10-28 --kind resume
```

Он передаёт зафиксированный `session_id` в `--resume`, явно задаёт ту же модель
и посылает SIGTERM группе сразу при чтении `system/init` (SIGKILL при необходимости).
Это проверяет наблюдаемую возможность остановки; отсутствие tool_call в потоке
само по себе не доказывает отсутствие начавшегося инструмента. Сверяются поток,
HTTP-журнал MCP и изменения файлов. Инструмент раньше init тоже вызывает остановку
и записывается как неподтверждённая защита, не успешная проверка.

Если первый старт сорвался по внешней причине, второй допускается только как
явный `--kind retry-first` после разбора ошибки; resume/kill останутся непроверенными.
Автоматических повторов нет. Резерв попытки сохраняется **до** spawn и не
возвращается при сбое: это консервативная граница бюджета, не банковский учёт.
Блокировка `paid.lock` исключает два одновременных платных исполнения в одном `--work`.
Третий старт запрещён. Создание нового `--work` не даёт нового платного бюджета.

## Выходные данные и границы

`run-N/`: stream.jsonl, stderr.txt, времена строк, argv.json, process.json,
summary.json, mcp-config.json, mcp-list-before.*, mcp.jsonl и filesystem-changes.json.
Из JSONL сохраняются неизвестные поля, session_id,
имя модели, result/usage/cost, если CLI их действительно прислал.
Оригинальные exit codes записаны, сигнальная остановка — отрицательный returncode Python.
`environment/host.json` — снимок подготовки, не текущий счётчик запусков.

Наблюдатель сравнивает `lstat` до/после в HOME run, клоне, отдельном TMPDIR и
перечисленных служебных каталогах CLI. Содержимое файлов не читается, ссылки
на Keychains не обходятся. Он фиксирует только сохранившиеся изменения:
временные файлы и запись за пределами списка не наблюдаются. Изменения реального
HOME могли сделать другие процессы. Пути требуют разбора; это не полная allowlist.

`fs_usage` при бесплатной проверке Артёмом вернул exit 0, но не дал событий
контрольного процесса даже при фильтрации PID самим инструментом. Поэтому
платные запуски используют проверенный снимок метаданных; подробность —
[fs-usage-failure.json](environment/fs-usage-failure.json). Дополнительную пробу
`trace-test --observer fs-usage` можно сделать бесплатно отдельно с `sudo -v`,
но она не является предусловием запуска модели. Полное наблюдение для профиля
BE-28, сборки, сеть и токен остаются неподтверждёнными; BE-29 сохраняется.

**Не проверено (бюджет):** rate-limit, usage/spendLimitHit,
resource_exhausted, молчаливый выход и живая подмена модели/fallbackModel.
Их нельзя целенаправленно вызвать двумя согласованными стартами; для BE-25
остаются синтетические fixtures с явной маркировкой. Квота вне MVP.

Живые init/result, HTTP-вызовы MCP с env-интерполяцией, usage, session/resume
и один опыт kill до инструмента подтверждены в [RESULTS.md](RESULTS.md).
Стоимость не пришла. Полнота файлового наблюдения остаётся ограничением.

Самопроверка обвязки без Cursor и без sudo:

```sh
python3 -m unittest discover -s spikes/backend -p test_be22.py -v
```

Официальные справочные источники, сверены 28.10.2026:
[формат потока](https://docs.cursor.com/en/cli/reference/output-format),
[авторизация](https://prod.cursor.com/docs/cli/reference/authentication),
[конфигурация](https://prod.cursor.com/docs/cli/reference/configuration).
Факты установленной версии выше подтверждаются локальными fixtures;
примеры документации не заменяют живой stream.
