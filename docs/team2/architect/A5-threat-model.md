# A5 / T10 — модель угроз изоляции агента

2026-10-04. Источники истины: архитектура v0.11.22 (§8.1–8.3, §9, §10, §13),
спека v0.8.24 (§1.5, UC-18, UC-24, UC-25), переданный team2 журнал решений.
Это вопросы и предложения Architect, не изменение принятой архитектуры.
Корпус синтаксиса git-команд относится к B3; здесь рассматриваются соседние
границы, прямые filesystem операции и доверенные процессы.

## Активы, доверие, scope

Защищаем основной репозиторий и refs других задач, конфиг проекта `.kaban`,
GitIdentity, БД и журналы демона, Cursor IDE/CLI токены, SSH/Keychain, настройки
MCP и право человека принимать результат. Агент, prompt, исходники, build scripts,
зависимости и разрешённый сторонний MCP считаются потенциально недоверенными.

Доверенные части: подписанный клиент, демон и DaemonGit, launcher, результатная
проверка и будущий egress proxy. Gate запускает код проекта: нужно явно решить,
является ли он ограниченным процессом, прежде чем считать его доверенным.
Клон — отдельное git repository, не worktree, но `clone --local` разделяет объекты
hardlink-ами (§8.1). Доступ инструментов к CLI-token принят как риск (§13), не
решён обещанием GitShim или проверки результата.

Проверка результата — граница **принятия изменений**, но не возвращает уже
прочитанный секрет, отправленные байты, выполненный hook или повреждённый inode.
Сценарий постфактум-инцидента UC-18 не заменяет профилактику этих последствий.

Статусы ниже: «описано» = архитектурная мера есть, production не проверена;
«частично» = мера не покрывает весь вектор; «открыто» = правило не определено;
«наблюдение» = воспроизведено только в существующем spike на synthetic markers.
Severity — последствия при выполнении предусловия, а не CVSS production finding.

## Непокрытые и частично покрытые векторы, сначала тяжёлые

### H1. Недоверенный git config вызывает код в доверенном DaemonGit (T/E)

Предусловие: локальный конфиг клона или его include/includeIf уже содержит helper;
либо агент может заменить config/родительский `.git`. Последствие: дочерний процесс
DaemonGit вне песочницы может исполнить hook, fsmonitor, SSH/credential helper,
filter/textconv/diff helper, editor/pager или обратиться к нежелательному remote.

Арх. §8.2 описывает запрет записи config/hooks/info и
`-c core.hooksPath=/dev/null -c core.fsmonitor=false`, а также отказ пользовательским
глобальным git-опциям, очистку `GIT_*`, editor=true и отсутствие system/global
конфигов. Это закрывает hooks/fsmonitor и унаследованные global/system источники
**при корректной реализации**, но не отключает repo-local include/includeIf,
`core.sshCommand`, `credential.helper`, filter drivers и local remote URL.
`GIT_CONFIG_GLOBAL=/dev/null` не значит «все конфиги выключены».

Вопрос Architect: проверять и нормализовать local config до первого доверенного
вызова, включая транзитивные includes, или выполнять DaemonGit в отдельной границе?
Каковы разрешённые config keys и команды DaemonGit с external-helper semantics?
Безопасная проверка: disposable repo, helper только пишет marker в его temp;
проверить каждый реально используемый путь DaemonGit. Не запускать настоящий
SSH, credential helper, сеть или конфиги пользователя. Статус: **частично**.

### H2. Shared object inode из `clone --local` повреждает основной repo (T/D)

Предусловие: объект клона hardlink-нут к основному репозиторию и профиль позволяет
in-place запись этого объекта. Последствие: порча объекта затрагивает основной repo
до post-run проверки; refs могут остаться неизменными, но объект уже повреждён.

Арх. §8.1 прямо выбирает hardlinks; §8.2 обещает запрет записи в основной repo,
но не определяет защиту shared inode через разрешённое имя клона. Это гипотеза
условного последствия, не выполненный exploit. APFS `cp -c` использует другую
семантику, не следует путать с hardlink. Вопрос Architect: `--no-hardlinks`, отдельная
immutable object storage либо explicit object-write запрет? Как проверяется inode
при подготовке клона и после warm_paths? Безопасный тест: только новый marker
outside/clone в temp, сравнить hash при in-place write через linked имя.
Статус: **открыто**, высокая серьёзность при разрешённой записи объектов.

### H3. Токен CLI доступен инструменту и выводится через разрешённую сеть (I/E)

Предусловие: один профиль содержит CLI и tools, CLI читает token; либо token/env/fd
передан инструменту. Последствие: чужие запросы от аккаунта, утечка приватных данных,
расход квоты. §13 признаёт риск; запрет IDE globalStorage не запрещает собственный
CLI-token. Keychain storage не делает секрет невидимым уже авторизованному CLI.

Hostname allowlist уменьшает каналы, но разрешённый сервис может принимать байты;
IP/порт SBPL не проверяет HTTP endpoint. Вопрос Architect: обязательный tool broker,
раздельные capabilities и token-free tool env/fd, утверждённые destinations? CLI
снаружи sandbox полезен только если все shell/read/edit/search/MCP пути обязательно
проходят broker. Parent CLI остаётся доверенным token holder. Проверять fake token
в temp, без настоящей авторизации; попытка прочитать и передать marker локальному
mock endpoint. Статус: **принятый остаточный риск**, feasibility спайка ещё открыта.

### H4. Внепесочный gate/on_create/dependency code обходит защиту run (E/T/I)

Предусловие: gate, warm cache executable, package install, on_create или build script
исполнен доверенным launcher без той же или более строгой границы. Последствие:
доступ к host secrets, mutation репозитория/демона до result check. §8.1 задаёт
warm_paths и on_create; §8.2 говорит о Seatbelt для агента, §14 о сборках, но полный
lifecycle perimeter не перечислен. Вопрос: кто и под каким профилем исполняет
каждый такой шаг, есть ли отдельная сеть для dependency fetch? Проверка: только
marker-touch из каждого lifecycle hook с ожидаемым отказом вне clone/scratch;
без загрузки пакетов и без настоящих секретов. Статус: **открыто**.

### H5. Spike не реализует требуемые protected-path запреты (T/E)

Наблюдение T3 на macOS27.0.1: копия существующего `kaban-agent.sb` с fake HOME,
CLONE и scratch в temp разрешила write/unlink `.git/config`, `.git/hooks/hook`,
`.git/info/exclude`, `.kaban/pipeline.yaml` (все 0), rename `.git`/`.kaban` (0).
Fake IDE marker через symlink не читался (1). Никакие реальные данные не трогались.

Причина: `spikes/backend/kaban-agent.sb:29–34` разрешает весь clone/temp;
`:46–52` не содержит clone protected paths; `spike6-seatbelt.sh:66–71` не передаёт
EXTRA_DENY_WRITE. Общий `/private/tmp` открывает marker другого run в том же temp.
Это **дефект fidelity спайка**, не доказанный production exploit. Severity P1/high
для готовности spike6 подтвердить §8.2. Центральный [issue #13](https://github.com/imedfan/kaban/issues/13) оформлен координатором.

Отдельный T3 документ `research/macos-seatbelt.md` (ветка team2/research-seatbelt,
коммит 9f5857c) содержит профиль и copyable synthetic probes. Исправленный
исследовательский кандидат: launch/clone/scratch/read-config=0, protected write/
unlink/rename/outside/symlink/descendant=1, hashes markers unchanged. Его общий
file-read* сохраняет confidentiality gaps; macOS26/CLI/build/network не проверены.
Вопрос: расширить spike на эти negative probes, не выдавая его за production profile?
Статус: **наблюдение**.

### M1. Symlink/gitdir/common-dir/alternates меняет реальное назначение (T/I)

Предусловие: путь внутри clone указывает наружу, в `.kaban` или чужую задачу;
`.git` заменён gitdir-файлом, submodule/common-dir/alternates указывает вне границы.
Последствие: чтение чужих файлов или изменение другого git storage. §8.2 запрещает
целевые пути, но canonicalization и replacement races не определены. Вопрос:
launcher проверяет реальные gitdir/common-dir, lstat/realpath и policy на submodules,
защищает родительские каталоги от rename/unlink? String prefix недостаточен.
Тест: только marker targets в temp; symlink write/read, rename protected parent,
изменение ссылки после проверки. Статус: **частично**, high при host target.

### M2. Env/PATH/TMPDIR или подмена executable меняет доверенный вызов (S/E)

Предусловие: agent-controlled PATH, TMPDIR/HOME или executable/symlink используется
DaemonGit либо launcher. Последствие: запуск чужого git/helper, повторное чтение
конфигов, подмена scratch/result. §8.2 очищает GIT_* и перечисляет разрешённые env,
но PATH/HOME/TMPDIR остаются; whitelist **имён** не гарантирует доверие **значениям**.
Loader vars вне whitelist должны отсутствовать. GitShim первым в PATH — UX-фильтр,
абсолютный `/usr/bin/git` агентом разрешает обход фильтра.
Вопрос: фиксировать canonical executable и доверенный PATH для DaemonGit отдельно
от tool PATH; per-run scratch с ownership; закрывать лишние fd? Проверка: fake git
в temp пишет marker; доверенный вызов обязан его не исполнить. Статус: **частично**.

### M3. MCP allowlist проверяет имя сервера, а не его полномочия (S/T/I/E)

Предусловие: config изменён между `mcp list` и run, имя allowlisted сервера осталось,
но command/argv/env/URL подменён; разрешённый MCP уже исполняет произвольный код.
Последствие: внешнее исполнение/утечка, обход sandbox через сервер с host правами.
§9 собирает config, проверяет лишние серверы fail closed и восстанавливает файл
до result check; это закрывает accidental discovery, но immutability config,
равенство full descriptor и scope MCP-process не определены.
Вопрос: фиксировать hash/full descriptor, запретить tool запись runtime MCP-конфига,
проверять server lifecycle/rights? Нельзя считать включение MCP доверенным sandbox.
Проверка: только два локальных mock server descriptors; новая/изменённая запись
не должна исполниться. Статус: **частично**; решения default board-only сохраняются.

### M4. Run-token превращается в confused deputy (S/E/T)

Предусловие: агент читает собственный bearer env, отправляет иной task/project/run
или replay после завершения; local процесс угадывает/получает token. Последствие:
чужие команды доски, списание чужого one-shot grant. §9 привязывает bearer к run,
задаче и стадии, §8.3 атомарно списывает grant, §13 bind только 127.0.0.1.
Самому run доступен его token по дизайну. Вопрос: server берёт identity из token,
не доверяет body/cwd, отзывает token при crash, ограничивает endpoints/grants и
проверяет фазу state machine? Loopback не аутентифицирует пользователя.
Проверка: mock A/B tokens, чужой task/cwd, повтор, expired token, concurrent calls;
никаких действующих токенов. Статус: **описано**, детали expiry/recovery проверить.

### M5. XPC клиент подделывает право человека (S/E/T)

Предусловие: локальный чужой процесс открывает Mach service или соединение принято
до проверки подписи; reused process identity проверена по PID без audit identity.
Последствие: allowGitOnce/approve/updatePipeline от имени человека. §13 требует
«только наш подписанный клиент», §5 commandId/idempotency; precise signature
requirement и проверка каждого connection не заданы.
Вопрос: designated requirement/team/bundle identity + audit token, поведение старого
клиента и fail-closed отказ? Проверка относится к T4: без системных изменений,
unsigned test client против локального test service. Статус: **описано**, не verified.

### M6. Проверка diff/acceptance TOCTOU и реальное чтение подозрительного файла (T/I)

Предусловие: живой descendant или другой клиент меняет clone после result check;
path принят человеком, blob изменился; symlink в UI diff указывает наружу.
Последствие: unreviewed content проходит merge, или preview читает secret.
§8.2/UC-25 привязывает acceptance к path+blob, stale_suspicious_files перепроверяет
набор и повторяет check до merge. Это сильная мера против stale UI, но freeze point,
quiescence tools и читается ли blob или filesystem target не определены.
Вопрос: остановить/дождаться всех writers, использовать immutable blob snapshot,
проверить symlink mode без разыменования? Тест: temp marker и смена blob/target
между review/accept/merge, ожидается stale или новая проверка. Статус: **частично**.

### M7. Прямые refs/HEAD/packed-refs обходят command policy (T/R)

Предусловие: профиль позволяет запись `.git` ради commit/fetch/index; shell пишет
storage напрямую. Последствие: policy/grant audit не отражает изменение, возможна
порча refs. §8.2 признаёт обход GitShim и проверяет результат, но write whitelist
refs задачи и metadata ещё нет; deny config/hooks/info не закрывает foreign_refs.
Вопрос: strict только daemon commits; в других presets какой kernel-level storage
perimeter плюс final snapshot? Проверка raw marker/storage в disposable repository,
корпус argv не дублировать B3. Статус: **частично**, обнаружение постфактум описано.

## STRIDE: покрытие оставшихся классов

| Класс | Вектор / предусловие | Текущая мера | Остаток / безопасная проверка |
|---|---|---|---|
| S — spoofing | Fake executable, MCP identity, token или XPC client | §8.2 env, §9 bearer и allowlist, §13 signature | M2–M5; идентичность проверять на trusted стороне |
| T — tampering | Config/helpers, shared inode, direct refs, mutable diff | §8.2 protected paths + result check; UC-18/25 | H1/H2/H5/M1/M6/M7; marker tests и immutable snapshots |
| R — repudiation | Агент отправляет ложный complete_stage summary; log injection скрывает факт | §5 журнал run/task, §6.3 daemon commit, §9 финальный вызов не сам переводит стадию | Структурированный authoritative audit: policy decision, normalized argv, actor/run, blob, result; sanitize control chars; fake multiline marker summary |
| I — disclosure | CLI token, env/fd, cache другого run, URL/query/stdout logs | §13 Keychain и masking, SSH/IDE deny, network allowlist | H3/M1/M3; masking не ловит encoding/chunks; fake canary без настоящих секретов |
| D — denial of service | Fork/descendant, disk/cache/output flood, hung helper, quota depletion | §6 таймаут/stall/process group, §3.2 WIP/max runs, §10 kill recovery | Process group не доказывает отсутствие escaped descendant; bounded fake output/tiny file only; спросить лимиты bytes/process/disk и cleanup ownership |
| E — elevation | Вызов trusted DaemonGit/gate/MCP/XPC с недоверенным input | §8.2 layer separation, §9 state machine, §13 signature | H1/H4/M3–M5; trusted broker не исполняет произвольный shell от caller |

D-вектор не тестировать fork bomb/заполнением диска. Для quota используются только
поддельные stream-json fixtures, для process cleanup — один harmless child marker
с коротким timeout. Ошибка parser/profile должна блокировать start, не снижать
изоляцию и не превращаться в многократные «прошедшие» negative tests.

## Вопросы Architect и критерии доказательства

1. Высокий приоритет: где находится обязательная граница исполнения всех lifecycle
   процессов; как исключаются local git helpers и shared writable objects?
2. Какая граница защищает секреты до result check и какие исключения token risk
   явно принимаются; broker действительно обязательный или экспериментальный?
3. Какие gitdir/refs/cache/MCP-descriptor/path/env значения считаются доверенными?
4. Кто гарантирует отсутствие writers между snapshot/check/accept/merge и recovery?
5. Какие network URL/destinations, XPC requirement, token expiry и resource limits
   являются проверяемыми acceptance criteria, а не implicit implementation choices?

Evidence gate: baseline pass, profile launch pass, targeted operation fail,
postcondition unchanged; повторить на целевом macOS26 с pinned CLI/git/toolchain.
Матрица выше относится к архитектуре, не служит утверждением готовности к релизу.

## Источники и выполненные проверки

- [Git config](https://git-scm.com/docs/git-config): local scopes/includes и executable
  helpers; [Git environment](https://git-scm.com/docs/git): config/environment controls.
- [Git clone](https://git-scm.com/docs/git-clone): local hardlink objects и no-hardlinks.
- [Apple DTS о SBPL](https://developer.apple.com/forums/thread/661939): custom language
  unsupported; [Apple network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client):
  TCP connection capability не фильтрует поток. Прочитано 2026-10-04.
- Переданные версии архитектуры/спеки/decisions-log указаны в начале; старые repo
  docs не использованы как источник актуальных решений.
- T3 synthetic probes выполнены на macOS27/Xcode27/Swift6.4: только temp markers,
  без чтения Cursor/SSH, Keychain/auth, internet/model вызовов и системных изменений.
- A5 не запускал exploits, production runtime или package tests: изменён только
  этот документ. `git diff --check` — проверка формата, не security validation.

Уверенность высокая в описании архитектурных мер и наблюдении спайка, средняя
в conditional threats, низкая в непроверенных production деталях. Все unresolved
предложения направлены Architect; исходники и решения проекта не изменены.
