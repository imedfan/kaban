# T2: MCP-конфиг запуска и fail closed

Дата проверки источников: **2026-10-04**. Исследование, не реализация.
Источник требований: architecture v0.11.22 §6, §8.2, §9, §13–14;
спека v0.8.24 UC-24, F26; decisions-log, раздел MCP.
Репозиторий: main `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.

Рекомендация: сначала проверять вариант A (подмена в клоне + отдельный
HOME), затем B (конфиг только в отдельном HOME). Оба требуют доказать,
что CLI не видит остальные источники и авторизация работает отдельно.
Если этого доказательства нет, запуск блокируется; реальный HOME не
становится автоматическим запасным вариантом.

## Что известно точно

* Cursor документирует project `.cursor/mcp.json` и global
  `~/.cursor/mcp.json`, интерполяцию `${env:NAME}` в том числе в `headers`,
  HTTP/SSE по `url` и Streamable HTTP. `envFile` относится только к stdio.
  Это описание продукта, а не результат проверки установленного CLI.
  [Cursor MCP](https://cursor.com/docs/mcp), просмотрено 2026-10-04.
* CLI документирует те же конфиги, порядок `project → global → nested`
  и поиск в родительских каталогах. `mcp list` описан как интерактивное
  меню с именами, источниками, транспортом и состоянием; `list-tools`
  получает инструменты. Документ не даёт контракт JSON-вывода, точную
  семантику коллизий имён или доказательство отсутствия подключения.
  [CLI MCP](https://cursor.com/docs/cli/mcp), просмотрено 2026-10-04.
* `--approve-mcps` одобряет **все** серверы; `--workspace` выбирает
  workspace, а не изолирует источники. Публичная таблица параметров не
  содержит `--mcp-config` или отключения всех внешних источников MCP.
  [CLI parameters](https://cursor.com/docs/cli/reference/parameters),
  просмотрено 2026-10-04.
* MCP 2025-06-18 требует проверки Origin сервером, рекомендует loopback
  и аутентификацию; POST Accept включает JSON и event-stream. Успешный
  curl ping доказывает доступность stub, но не интеграцию Cursor.
  [MCP transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports),
  версия 2025-06-18, просмотрено 2026-10-04.

Backend team2 сообщил только результаты bounded `--help`/`--version`:
CLI `2026.09.23-86fc751`, exit 0; `--approve-mcps`, `--workspace`,
`--api-key`/`CURSOR_API_KEY`, `--trust`, `--sandbox enabled|disabled`;
нет `--mcp-config`/`--config`; `mcp` имеет list/list-tools/login/enable/disable.
Это локальное наблюдение конкретной версии, не гарантия для mbp.
Здесь CLI не запускался, credentials/личный конфиг не читались.
Авторизация и headless-флаги подробно относятся к T1/B5.

## Политика Kaban и предварительные условия

Ожидаемый набор: `{kaban-board} ∪ (stageSelection ∩ projectAllowlist)`.
Allowlist хранится на Маке; изменение файла в Git не добавляет разрешение.
Выбранный, но выключенный сервер пропускается с предупреждением
`mcp_not_allowlisted`. Нельзя передавать CLI исходный JSON и надеяться,
что `--approve-mcps` выберет только разрешённые записи.

Для каждой записи сохранять источник (`project`/`personal`), имя и
утверждённый снимок определения: transport, URL/command, args, env-ссылки,
headers, cwd, envFile. Имя `kaban-board` зарезервировано за демоном.
Одинаковое имя не доказывает одинаковые права: смена URL или команды
при том же имени требует повторной проверки доверенного снимка.
Это предложение укрепления §9; текущая архитектура явно требует
сравнения списка серверов, но не описывает fingerprint определения.

Перед **любым** `mcp list` нужны очищенные источники. Пока не доказано
обратное, discovery может подключаться к HTTP или запускать stdio.
Проверка после чтения чужого конфига может быть слишком поздней.
Пробы ниже используют только собственные loopback-серверы и temp HOME.

Предложенная последовательность: получить lock клона → зафиксировать
base main и исходные bytes/отсутствие конфига → отклонить symlink/nonregular
пути → собрать разрешённые определения → скрыть остальные источники →
запустить bounded discovery с теми же cwd/env/CLI/profile, что и run →
строго проверить полный набор → разрешить старт. Защитить сгенерированные
файлы и источники от изменений между проверкой и запуском и на всём run.
Результат проверки не переносится между версиями CLI или окружениями.

Любой лишний сервер даёт `unavailable: mcp_unexpected` с именем, run
не стартует. Пустой/обрезанный/непонятный вывод, timeout, ненулевой exit,
дубликат или отсутствие доски также блокируют старт: код ошибки для
этих случаев надо согласовать, не приписывать его протоколу.

## Варианты изоляции

| Вариант | Как | Плюсы | Минусы и условия принятия |
|---|---|---|---|
| A: подмена клона + temp HOME | Сгенерированный `.cursor/mcp.json` в клоне; пустой HOME; отдельная авторизация процесса | Совпадает с §9; cwd клона сохранён; простая проверка project-сервера | Временный diff; требуется восстановление после сбоя; HOME может разлогинить CLI; родительские/nested/plugin-источники нужно отдельно исключить |
| B: только temp HOME | Сгенерированный `$HOME/.cursor/mcp.json`; исходный project-конфиг скрыт на время run | Доска не записывается в репозиторий; тот же run-конфиг для нескольких чистых workspace | **Одного HOME недостаточно**: committed project и parent/nested конфиги продолжают обнаруживаться; скрытие исходного файла всё ещё меняет вид клона; проверка логина обязательна |
| C: явный конфиг/источники CLI | Если новая версия даст флаг полной замены MCP и запрет остальных источников, файл хранится вне клона | Предпочтительный вариант без изменений клона; проще атомарность | В проверенной help такого интерфейса нет; MCP-семантика CURSOR_CONFIG_DIR требует пробы; parent-конфиг не изолирует источники; не выдумывать флаг |

B не означает «сохранить committed config и добавить доску в HOME»:
это смешивание источников, отрицательная проба ниже должна выявить его.
`CURSOR_CONFIG_DIR` документирован для переноса CLI configuration, но
перенос global MCP и отключение других источников этим не доказаны.
[CLI configuration](https://cursor.com/docs/cli/reference/configuration),
просмотрено 2026-10-04. Проверять отдельно, сохраняя fail closed. Parent `.cursor/mcp.json` — источник discovery, а не граница.
`mcp disable`/enable меняют сохранённое одобрение и не заменяют allowlist.
Не менять реальный `~/.cursor/mcp.json`, login или permissions пользователя.

Отдельный HOME **не обещает сохранение логина**. Проверка status в том
же окружении — задача T1, без модели и с удалением персональных данных
из фикстур. Если нужен API key, только отдельное согласованное получение
демоном из Keychain и env процесса; не копировать credential-файлы,
не создавать symlink к реальному HOME и не класть ключ в argv/JSON.

Для A/B после run и при recovery восстановить `.cursor/mcp.json` из
зафиксированной базы main, включая индекс, либо удалить сгенерированный
файл, если в базе его не было. `info/exclude` скрывает только untracked
файл, не tracked diff. Не использовать skip-worktree/assume-unchanged
как границу. Nested/parent/plugin-конфиги тоже должны быть покрыты
проверкой; восстановление одного root-файла их не нейтрализует.

## Чек-лист mbp: безопасные discovery-пробы без модели

Выполнять блоки последовательно в одной zsh-сессии. Не запускать
существующий spike2 целиком в этой фазе: он содержит платные `-p`
запуски, `--approve-mcps` и пробу real HOME. Ниже нет login, approvals,
status или модели. Все конфиги синтетические; KABAN_RUN_TOKEN —
заведомо фиктивный токен stub, не токен демона.

### 1. Изолированные каталоги, runner и два stub

```sh
K2_REPO="$(pwd -P)"  # execute from the repository root
K2_CA="$(command -v cursor-agent)"
K2_PY="$(command -v python3)"
K2_TMP="$(mktemp -d /private/tmp/kaban-t2-mcp.XXXXXX)"
export K2_REPO K2_CA K2_PY K2_TMP
mkdir -p "$K2_TMP/home/.cursor" "$K2_TMP/parent/task/.cursor" "$K2_TMP/out"
export KABAN_RUN_TOKEN=kaban-t2-synthetic-not-a-credential
"$K2_PY" "$K2_REPO/spikes/backend/mcp_stub_server.py" \
  --port 0 --port-file "$K2_TMP/board.port" --log "$K2_TMP/out/board.jsonl" \
  --name kaban-board >"$K2_TMP/out/board.stdout" 2>"$K2_TMP/out/board.stderr" &
K2_BOARD_PID=$!
"$K2_PY" "$K2_REPO/spikes/backend/mcp_stub_server.py" \
  --port 0 --port-file "$K2_TMP/dummy.port" --log "$K2_TMP/out/dummy.jsonl" \
  --name project-dummy --no-auth \
  >"$K2_TMP/out/dummy.stdout" 2>"$K2_TMP/out/dummy.stderr" &
K2_DUMMY_PID=$!
trap 'kill "$K2_BOARD_PID" "$K2_DUMMY_PID" 2>/dev/null' EXIT
"$K2_PY" - <<'PY'
import os, pathlib, time
p = pathlib.Path(os.environ['K2_TMP'])
for _ in range(50):
    if all((p / n).exists() for n in ('board.port', 'dummy.port')):
        break
    time.sleep(.1)
else:
    raise SystemExit('stub startup failed; stop here')
PY
cat > "$K2_TMP/probe.py" <<'PY'
import json, os, pathlib, signal, subprocess, sys
root = pathlib.Path(os.environ['K2_TMP'])
label, *args = sys.argv[1:]
# No inherited API key, config-dir overrides, or authentication env.
env = {'HOME': str(root / 'home'), 'PATH': os.environ['PATH'],
       'TMPDIR': str(root), 'LANG': 'en_US.UTF-8',
       'KABAN_RUN_TOKEN': 'kaban-t2-synthetic-not-a-credential'}
prefix = root / 'out' / label
with open(str(prefix)+'.stdout', 'wb') as out, open(str(prefix)+'.stderr', 'wb') as err:
    proc = subprocess.Popen([os.environ['K2_CA'], *args],
        cwd=root / 'parent/task', env=env, stdin=subprocess.DEVNULL,
        stdout=out, stderr=err, start_new_session=True)
    timed_out = False
    try:
        rc = proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            rc = proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            rc = proc.wait()
prefix.with_suffix('.meta.json').write_text(json.dumps(
    {'argv': args, 'exit': rc, 'timeout': timed_out, 'cwd': 'synthetic-task'}))
print(label, 'exit', rc, 'timeout', timed_out)
PY
"$K2_PY" "$K2_TMP/probe.py" version --version
"$K2_PY" "$K2_TMP/probe.py" help --help
"$K2_PY" "$K2_TMP/probe.py" mcp-help mcp --help
```

Ожидается: два port-файла, version/help завершаются без модели.
Если HOME-override всё равно использует личные серверы, остановить
CLI-пробы: HOME не изолирует эту версию. Не включать/одобрять серверы.
Данный runner ограничивает время, **не является OS-песочницей**.

### 2. Project, global, parent, одинаковые имена, подмена

```sh
cat > "$K2_TMP/config.py" <<'PY'
import json, os, pathlib, sys
r = pathlib.Path(os.environ['K2_TMP'])
task = r / 'parent/task'
board = {'url': 'http://127.0.0.1:'+(r/'board.port').read_text().strip()+'/mcp',
         'headers': {'Authorization': 'Bearer ${env:KABAN_RUN_TOKEN}'}}
dummy = {'url': 'http://127.0.0.1:'+(r/'dummy.port').read_text().strip()+'/mcp'}
paths = [task/'.cursor/mcp.json', r/'home/.cursor/mcp.json', r/'parent/.cursor/mcp.json']
for p in paths:
    p.unlink(missing_ok=True)
phase = sys.argv[1]
configs = {
 'project': [(0, {'kaban-board': board})],
 'global': [(1, {'kaban-board': board})],
 'union': [(0, {'project-dummy': dummy}), (1, {'kaban-board': board})],
 'parent': [(2, {'project-dummy': dummy}), (0, {'kaban-board': board})],
 'collision': [(0, {'kaban-board': dummy}), (1, {'kaban-board': board})],
 'replace': [(0, {'kaban-board': board})],
}
for index, servers in configs[phase]:
    p = paths[index]
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({'mcpServers': servers}, indent=2)+'\n')
PY
for K2_PHASE in project global union parent collision replace; do
  "$K2_PY" "$K2_TMP/config.py" "$K2_PHASE"
  "$K2_PY" "$K2_TMP/probe.py" "$K2_PHASE-list" mcp list
  "$K2_PY" "$K2_TMP/probe.py" "$K2_PHASE-tools" mcp list-tools kaban-board
 done
```

| Фаза | Что должно быть установлено; принять/отклонить |
|---|---|
| project | Доска видна из cwd; при HTTP-подключении `auth=match` в board.jsonl |
| global | Доска видна без project-файла; это проверка B, не доказательство авторизации CLI |
| union | Extra `project-dummy` должен блокировать run; B без удаления project-файла непригоден |
| parent | Установить реальный поиск вверх и наличие extra; нельзя считать корень Git границей |
| collision | Только имя `kaban-board` не различает две реализации; запросы к dummy означают подмену |
| replace | Только доска; dummy не получает новых запросов после очищения источников |

Каждая фаза может закончиться timeout/approval-required. Это **не pass**,
не повод добавлять `--approve-mcps`, а фикстура несовместимого preflight.
Сравнить позиции логов до/после фаз, source/URL и статус в выводе.
Если `list` не подключается, `list-tools` проверяет headers без модели;
если требует одобрения — записать «HTTP CLI не подтверждён».

### 3. Закоммиченный конфиг и восстановление

```sh
"$K2_PY" "$K2_TMP/config.py" union
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$K2_TMP/parent/task" init -q -b main
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$K2_TMP/parent/task" add .cursor/mcp.json
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$K2_TMP/parent/task" -c user.name=Team2 \
  -c user.email=team2@example.com -c core.hooksPath=/dev/null commit -qm fixture
"$K2_PY" "$K2_TMP/config.py" replace
"$K2_PY" "$K2_TMP/probe.py" committed-replaced mcp list
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$K2_TMP/parent/task" restore --source=main --staged --worktree .cursor/mcp.json
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$K2_TMP/parent/task" status --porcelain > "$K2_TMP/out/restored-status.txt"
```

Ожидается: committed dummy больше не виден при `committed-replaced`,
после restore status пустой, исходный JSON содержит project-dummy.
Для отсутствовавшего файла отдельно проверить удаление generated-файла
и восстановление `info/exclude`; symlink и nested `.cursor/mcp.json`
должны быть отрицательными тестами реализации, без внешних целей.

### 4. Принятие результатов и фикстуры

Сохранить вне Git `$K2_TMP/out`: version/help, каждый stdout/stderr,
meta (exit/timeout), board/dummy JSONL с классификацией auth, исходный
synthetic JSON и результат restore. В fixtures для тестов перенести только
синтетические, проверенные на отсутствие PII данные. Не сохранять env,
реальные JSON, ключи, полный status, токены, shell history или `ps e`.

Матрица дополнительных проверок: malformed/duplicate JSON keys; одинаковые
имена из двух источников; disabled server; nested-конфиг; parent с extra;
extra stdio (только заранее проверенный sentinel в temp, без shell/network);
запрет чтения real HOME; изменение JSON между discovery и стартом;
отсутствующий env токен; crash до/после подмены; обновление CLI.
Не запускать неизвестный committed stdio даже для `mcp list`.

Критерий готовности M2: A или B подтверждён на конкретном CLI, все extra
и коллизии блокируют start до исполнения, board HTTP подтверждён, auth
из T1 проверена в том же окружении, строгий parser полностью декодирует
вывод/ошибки и восстанавливает конфиг при recovery. До этого: исследование
готово, production-isolation **не подтверждена**.

## Находка и открытые вопросы основной команде

* **P1, исследовательский helper не является security parser.**
  `spikes/backend/lib/kspike.py:1091–1115` ищет подстроки имён, выводит
  `other_lines`, всегда возвращает 0. Extra не сравнивается с полным
  разрешённым набором. `spike2-mcp.sh` проверяет known dummy/missing,
  а не строгий набор. Это допустимая диагностика spike, но копировать
  её в production fail-closed нельзя. Без изменения существующего кода.
* §9: как исключить parent/nested/plugin/team источники и auto-start
  stdio до discovery? Есть ли проверяемый noninteractive listing API?
* §9/UC-24: будет ли изменение определения allowlisted имени отзывать
  разрешение? Как разрешать коллизию project/personal имён?
* §8.2/§10: кто защищает конфиг в течение run и делает restore при crash?
* T1: авторизация с temp HOME и одинаковым env под launchd пока неизвестна.
  Остаточный риск чтения собственного CLI-токена из §13 сохраняется.

Проверено здесь: источники, existing spike2/stub/helper/README только чтением,
синтаксис embedded shell/Python, безопасная синтетическая воспроизводимость
helper-находки. CLI discovery, auth и model calls здесь не выполнялись.
