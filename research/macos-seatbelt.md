# T3 — Seatbelt для спайка 6

Дата исследования: 2026-10-04. Источники проекта: свежая архитектура
v0.11.22 (§8.2, §13, §14), спека v0.8.24 (§1.5, UC-18, UC-25),
журнал решений из переданного team2-контекста. Файлы в `spikes/` только прочитаны.

## Вывод и достоверность

`sandbox-exec` есть на исследовательском хосте macOS **27.0.1 (26A434)**,
Xcode **27.0**, Swift **6.4**. Это **не проверка macOS 26**.
Локальный `man sandbox-exec` помечает команду DEPRECATED; `-h` возвращает usage
с `-f`, `-n`, `-p`, `-D`. Apple DTS объясняет, что язык SBPL не поддерживается
для сторонней разработки. Наличие бинарника не обещает будущую совместимость.

Обычный запуск безопасного `/usr/bin/true` получил
`sandbox-exec: sandbox_apply: Operation not permitted` в уже ограниченной среде
Codex. Повтор через разрешённый автоматической проверкой запуск вне внешней
песочницы, с `(version 1)(allow default)(deny file-write*)`, завершился с кодом 0.
Это подтверждает базовый запуск на этом хосте; права профиля проверены ниже на искусственных маркерах.
Никакие реальные токены, SSH-файлы или данные Cursor не читались.

Текущий `spikes/backend/kaban-agent.sb` — **allow-default эксперимент**, а не
готовая граница изоляции. Черновик ниже — deny-default для безопасных проб
инструментов; его нельзя объявлять рабочим профилем Cursor или Swift-сборок до
проверки зависимостей. Первоначальный вариант с whitelist чтения завершался
SIGABRT (134) даже на true. Основной кандидат ниже использует общий file-read*
с явными запретами секретов: это граница записи/сети, но не полная изоляция чтения.
Узкий список необходимых launch read paths ещё не найден.
Production-решение и принятый риск остаются за Architect.

## Что видно точно в текущем спайке

| Наблюдение | Доказательство и влияние |
|---|---|
| Чтение почти всего разрешено | `(allow default)`, затем два запрета: SSH и Cursor globalStorage. Другие секреты и токен CLI остаются доступны, если расположены вне этих путей. |
| Внешняя сеть открыта | Запрещён только `localhost:*`, затем разрешён MCP-порт. Нет default-deny сети или обязательного прокси. |
| Запись шире клона | Разрешены весь TMPDIR, CACHEDIR, `/private/tmp`, `/private/var/tmp`, устройства и EXTRA_WRITE. Это подходит поиску зависимостей, но не обещанию «только клон». |
| Нет запретов защищённых путей клона | В шаблоне отсутствуют `.git/config`, `.git/hooks`, `.git/info`, `.kaban`; EXTRA_DENY_WRITE в `render()` не передаётся. Арх. §8.2 требует эти запреты. Прямые записи из shell не проходят GitShim. |
| Проверка не покрывает эти пути | `write_probe()` проверяет основной репозиторий, внешний файл, клон, temp, SSH и state.vscdb; отсутствуют config/hooks/info/.kaban, замена каталогов и ссылки. |
| Проверка читает реальную IDE-базу | `dd if="$DB" ... count=1` не печатает значение, но выполняет чтение. Для новых безопасных проб ниже используется только искусственная база. |

Находка оформлена как [issue #13](https://github.com/imedfan/kaban/issues/13).

Это расхождения **спайка с целевыми требованиями**, не утверждение об уже
реализованной уязвимости демона. Не менять спайк в рамках T3.

## Фактически воспроизведено на macOS 27

Без изменений спайка его шаблон подставлен с FAKE_HOME/CLONE/SCRATCH в единственной
папке `/private/tmp/kaban-team2-seatbelt-validation`. Все файлы — `marker`.
Повтор через разрешённый автоматической проверкой запуск вне Codex-песочницы:

| Проба с текущим spike-профилем | Код | Оценка |
|---|---:|---|
| `/usr/bin/true`; touch clone/scratch; read clone config | 0 | Контроли проходят |
| Чтение fake state.vscdb через symlink в клоне | 1 | Запрет чтения действует в этой пробе |
| Write и unlink `.git/config`, `.git/hooks/hook`, `.git/info/exclude`, `.kaban/pipeline.yaml` | 0 каждый | Воспроизведённое несоответствие §8.2 |
| Rename каталогов `.git` и `.kaban` | 0 каждый | Защищённые пути можно заменить |
| Write через symlink в `.kaban` | 0 | Запрета .kaban в шаблоне нет |
| Touch вне клона, write через внешний symlink, touch дочерним shell | 0 каждый | Все targets внутри `/private/tmp`, который шаблон разрешает целиком |

Последняя строка **не** доказывает escape в произвольный HOME: она доказывает,
что temp-папка чужого run не отделена от этой. Network и hardlink probes не
исполнялись. Реальные чувствительные пути не читались. Для воспроизведения
использовать setup ниже и подставить маркерные HOME/CLONE/TMPDIR/CACHEDIR в копию
существующего шаблона; пустые EXTRA_*; исходный файл не менять. Не применять
ожидание `outside=fail` к текущему шаблону, если outside лежит в `/private/tmp`.

## Результаты исправленного кандидата на хосте 27

Для Scheme-блока ниже, с теми же disposable markers и argv функции `sb`:

```text
compile=0 clone=0 scratch=0 read-config=0
ide-link=1 outside=1 outside-link=1 kaban-link=1
write-.git/config=1 unlink-.git/config=1
write-.git/hooks/hook=1 unlink-.git/hooks/hook=1
write-.git/info/exclude=1 unlink-.git/info/exclude=1
write-.kaban/pipeline.yaml=1 unlink-.kaban/pipeline.yaml=1
rename-git=1 rename-kaban=1 child=1
```

После проб все четыре защищённых marker-файла и outside сохранили `marker`;
положительные allowed-файлы созданы. Исходный ограниченный whitelist reads
не запускался (134), поэтому заменён на явно описанный общий read allowance.
Все результаты относятся к **macOS27**, на Mac26 нужна повторная проверка.
Сеть, hardlinks и runtime Cursor не проверены этим набором.

## Черновик профиля инструментов

Скопировать блок в `tool.sb` внутри созданной ниже временной папки. Передавать
`-D` только абсолютные физические пути, полученные доверенным launcher до старта.
`FAKE_HOME` предназначен только для проб; в проектном профиле это физический HOME.
Не полагаться на утверждение «последнее правило побеждает» как на контракт Apple:
разрешение записи уже исключает защищённые пути через `require-not`.

```scheme
(version 1)
(deny default)

(allow process-exec)
(allow process-fork)
(allow file-map-executable)
(allow sysctl-read)

;; Research compromise: general reads until narrow launch paths are known.
;; This is write/network confinement, not a confidentiality whitelist.
(allow file-read*)

(allow file-write*
  (require-all
    (subpath (param "CLONE"))
    (require-not (subpath (string-append (param "CLONE") "/.git")))
    (require-not (subpath (string-append (param "CLONE") "/.kaban"))))
  (subpath (param "SCRATCH"))
  (literal "/dev/null"))

;; Пробы не разрешают агенту никакую запись в .git, включая refs/index.
;; Это сознательно строже §8.2, подходит strict/read-only git.
(deny file-write*
  (subpath (string-append (param "CLONE") "/.git"))
  (subpath (string-append (param "CLONE") "/.kaban")))
(deny file-read*
  (subpath (string-append (param "FAKE_HOME") "/.ssh"))
  (subpath (string-append (param "FAKE_HOME")
    "/Library/Application Support/Cursor/User/globalStorage"))
  (literal (string-append (param "FAKE_HOME")
    "/Library/Application Support/Cursor/User/globalStorage/state.vscdb")))

;; По умолчанию вся сеть запрещена. Только локальный MCP и будущий proxy.
;; Значения — строки портов; proxy обязан fail closed проверять назначения.
(allow network-outbound
  (remote ip (string-append "localhost:" (param "MCP_PORT")))
  (remote ip (string-append "localhost:" (param "PROXY_PORT"))))
```

Клон и scratch должны быть соседними отдельными каталогами. Нельзя разрешать их
общего родителя: это снова откроет protected paths и внешние файлы. Profile, launcher,
прокси, исполняемый GitShim и журналы хранятся **вне** обоих разрешённых каталогов.
Не добавлять весь HOME, `/private/tmp`, пользовательский CACHEDIR или toolchain
на запись ради одного отказа. Для runtime/cache допустим отдельный per-run каталог;
любое исключение требует минимального воспроизводящего теста и повторения запретов.

Для standard/permissive git необходим второй профиль: read-only `.git` плюс строго
выделенные writable index/objects/refs задачи. Просто разрешить `.git` и запрещать
три файла недостаточно для hard invariant `foreign_refs`: можно напрямую изменить
refs/packed-refs/HEAD. Запретить также их родительские каталоги от rename/unlink,
lock-файлы config и замену `.git`. GitShim — удобный фильтр, обход `/usr/bin/git`
и прямые записи остаются вне него. Конкретный whitelist git-хранилища — открытый
вопрос; приведённый strict-профиль не обещает поддержки commit/fetch/rebase.

## Ссылки, зависимости и сеть

- `cwd` не является границей. Symlink из клона наружу, в `.kaban`, к `state.vscdb`
  должен отказать по фактическому target. Проверять чтение, write, rename, unlink
  отдельно; не подставлять только лексически нормализованные пути.
- `.git` может быть файлом с `gitdir:`; submodule имеет собственный gitdir, common-dir
  и alternates. Для Kaban требуются самостоятельные клоны, а не git worktree.
  Launcher проверяет фактические gitdir/common-dir и не допускает выход наружу.
- `git clone --local` может разделять inode объектов hardlink-ами. Уже имеющийся
  hardlink в разрешённом каталоге нельзя считать закрытым одним запретом другого
  имени: in-place write может затронуть внешний inode. Безопасное исходное условие:
  копии без shared writable inode (`--no-hardlinks` для отдельных клонов), проверка
  link count и политика ссылок при подготовке. APFS clonefile не равен hardlink.
- Подключённые runtime, dyld/frameworks, Node/Python, Xcode SDK, SwiftPM, linker,
  package caches, temp, Unix sockets и Mach services проверяются отдельно.
  Уже открытые fd, сокеты, cwd, env и секреты в памяти тоже входят в границу;
  launcher закрывает лишние fd и собирает env с нуля. SBPL не очищает память/env.
- SBPL-фильтр IP/порт — не allowlist URL/HTTPS hostname. DNS, CDN, смена адресов,
  IPv6 и общий IP нескольких доменов исключают надёжную доменную политику на IP.
  Принятый parser-ом hostname ещё не подтверждает проверку SNI/Host.
- Практический вариант: deny сетевой доступ инструментам, разрешить только MCP
  и локальный доверенный egress proxy. Proxy проверяет hostname/порт/redirect,
  CONNECT, IPv4/IPv6, приватные адреса и DNS rebinding; не даёт raw tunnel к любому
  серверу. Proxy находится вне task clone. `HTTP_PROXY` один без блокировки прямой
  сети обходится. MCP-порт и proxy-port не должны совпадать с чужими сервисами.
- Даже разрешённый endpoint может принимать утечки в запросах. Это остаточный
  риск, а не доказательство защиты токена. MCP проверяет bearer/run/task на сервере.
  Ошибка сети/timeout не доказывает отказ Sandbox: нужен контроль без профиля.

## CLI снаружи, инструменты внутри

Арх. §13 предлагает эту схему как цель спайка, а не как имеющуюся возможность.
CLI вне профиля сможет читать токен и обращаться к Cursor; shell и **каждый**
file/search/edit/build/MCP-инструмент должны пересекать обязательный доверенный
broker, который запускает процесс под профилем. Обёртка `git` или shell в PATH
не гарантирует этот переход: встроенная запись файла, абсолютный путь и иной MCP
могут её обойти. `--sandbox enabled`/`sandbox run` сначала подтвердить по help
установленной версии CLI и по отрицательным тестам; флаг сам не свидетельство.

Критерий feasibility: без модели получить документированный механизм перехвата
всех tool executions; затем в оплачиваемом спайке с явной моделью проверить
shell, встроенный read/write/edit/search, дочерний процесс, MCP и resume. Нет
перехвата хотя бы одного — не заявлять tool-only границу. Если CLI сам обрабатывает
недоверенный prompt и может обращаться к токену, внепесочный CLI остаётся доверенной
частью с собственным риском. Песочница потомков не защищает память родителя от
самого родителя. Не передавать CLI-token в env/fd инструментов. Run-token доски
должен давать только ограниченные права текущего run и отзываться при завершении.

## Безопасные команды на mbp: ожидается pass/fail

Всё создаётся в `/private/tmp`; реальный HOME и Cursor не используются. Не запускать
оригинальный spike6 как безопасную замену: он включает реальные данные и модель.
Скопировать Scheme-блок выше в `$T3_ROOT/tool.sb` после setup.

```bash
T3_ROOT=$(mktemp -d /private/tmp/kaban-team2-seatbelt.XXXXXX)
T3_CLONE="$T3_ROOT/clone"
T3_SCRATCH="$T3_ROOT/scratch"
T3_HOME="$T3_ROOT/fake-home"
mkdir -p "$T3_CLONE/.git/hooks" "$T3_CLONE/.git/info" "$T3_CLONE/.kaban" \
  "$T3_SCRATCH" "$T3_HOME/.ssh" \
  "$T3_HOME/Library/Application Support/Cursor/User/globalStorage"
printf marker > "$T3_ROOT/outside"
printf marker > "$T3_CLONE/.git/config"
printf marker > "$T3_CLONE/.git/hooks/hook"
printf marker > "$T3_CLONE/.git/info/exclude"
printf marker > "$T3_CLONE/.kaban/pipeline.yaml"
printf marker > "$T3_HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
ln -s "$T3_ROOT/outside" "$T3_CLONE/outside-link"
ln -s "$T3_CLONE/.kaban/pipeline.yaml" "$T3_CLONE/kaban-link"
ln -s "$T3_HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
  "$T3_CLONE/ide-link"
# Save Scheme block to $T3_ROOT/tool.sb now.
sb() {
  /usr/bin/sandbox-exec -f "$T3_ROOT/tool.sb" \
    -D "CLONE=$T3_CLONE" -D "SCRATCH=$T3_SCRATCH" -D "FAKE_HOME=$T3_HOME" \
    -D MCP_PORT=43191 -D PROXY_PORT=43192 "$@"
}
sb /usr/bin/true                         # pass: parser + launch
sb /usr/bin/touch "$T3_CLONE/allowed"     # pass
sb /usr/bin/touch "$T3_SCRATCH/allowed"   # pass
sb /bin/cat "$T3_CLONE/.git/config" >/dev/null # pass: read config
sb /bin/cat "$T3_CLONE/ide-link" >/dev/null   # fail: artificial IDE marker
sb /usr/bin/touch "$T3_ROOT/forbidden"    # fail: outside clone/scratch
sb /bin/sh -c 'printf x > "$1"' sh "$T3_CLONE/outside-link" # fail
sb /bin/sh -c 'printf x > "$1"' sh "$T3_CLONE/kaban-link"   # fail
for T3_PATH in .git/config .git/hooks/hook .git/info/exclude .kaban/pipeline.yaml; do
  sb /bin/sh -c 'printf x > "$1"' sh "$T3_CLONE/$T3_PATH"  # each fail
  sb /bin/rm "$T3_CLONE/$T3_PATH"                         # each fail
  # Record each exit status immediately; do not inspect real file contents.
done
sb /bin/mv "$T3_CLONE/.git" "$T3_CLONE/git-replaced"       # fail
sb /bin/mv "$T3_CLONE/.kaban" "$T3_CLONE/kaban-replaced"   # fail
sb /bin/sh -c '/usr/bin/touch "$1"' sh "$T3_ROOT/child"    # fail: descendant
```

Baseline: repeat forbidden operations **only on disposable marker copies** without
`sb`; they must succeed. Record stderr and exit code for every operation; shell
nonzero is necessary but not sufficient until baseline and postconditions agree.
Do not treat a failed profile launch as many successful denials. Pre-existing
marker files must retain size/content; record a hash outside the sandbox, not data.

Network: start two harmless loopback HTTP listeners outside the profile, on 43191
and 43193, with document root an empty folder inside `$T3_ROOT`; no real MCP/token.
`sb /usr/bin/curl --noproxy '*' --max-time 2 http://127.0.0.1:43191/` should pass;
same to 43193 should fail; baseline to both should pass. Do not contact internet.
Use `/usr/bin/python3 -m http.server PORT --bind 127.0.0.1 --directory EMPTY_DIR`
if available, preserve listener stderr, stop only the recorded listener PID.
Repeat IPv6 using a listener explicitly bound to `::1`: require the production
profile to block every non-allowlisted port, even if the IPv4 probe passed.
No listener on proxy port means refusal is not a proxy-policy test.

Optional hardlink marker probe: outside sandbox create a **new** `outside-inode`
marker under `$T3_ROOT`, hardlink it into the disposable clone, hash before/after,
and attempt in-place write through the clone link. Any changed outside hash is a
failed boundary assumption. Never link a real repository object or sensitive file.
Also try creating a new hardlink inside sandbox from the outside marker: expect
fail under deny-default read/write rules. Keep these results distinct.

## Что проверить и сохранить

- На **целевом macOS 26**: OS/build, Xcode/Swift/CLI versions, command availability,
  profile parse/launch, every positive/negative marker test and baseline.
- Raw exit/status/stderr, rendered `.sb`, sanitized argv, fixture hashes, parent/
  child behavior, IPv4/IPv6, rename/unlink/symlink/hardlink outcomes, failed dependency
  and the narrowest added entitlement/rule. No home path, bearer, DB or prompts.
- В Swift/git сборках: compile/link/status и минимальный build сначала без сети;
  package fetch отдельно через proxy. Нужные дополнительные Mach-services и fd
  не выводить из одного успешного `/usr/bin/true`.
- Profile compile/apply failure must set sandboxOK=false and prevent launch;
  не продолжать без песочницы ради доступности. Отрицательный результат — fixture.

Открытые вопросы Architect: допустима ли зависимость production от unsupported
SBPL; кто гарантирует обязательный tool broker; какие git internals могут писаться
агентом при hard invariant foreign_refs; какие exact egress endpoints разрешены;
допустимы ли per-run cache/scratch; где хранится CLI-token и кто принимает его риск.
Уверенность высокая в статическом описании спайка и статусе API, средняя в кандидате
до macOS26/CLI/build тестов. Реальные Cursor/auth/model прогоны в T3 не выполнялись.

## Первичные источники (прочитаны 2026-10-04)

- [Apple DTS: custom sandbox / SBPL unsupported](https://developer.apple.com/forums/thread/661939),
  ответы Apple Staff Sep 2020 / Nov 2021; причина deprecation, не обещание статуса 26.
- [Apple App Sandbox](https://developer.apple.com/documentation/security/app_sandbox):
  поддерживаемый entitlement-механизм; он не заменяет произвольный per-run SBPL.
- [Apple network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client):
  права TCP соединения не фильтруют содержимое потока или hostname.
- [Apple sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html):
  child entitlement inheritance относится к App Sandbox, не доказательство профиля Cursor.
- Локальные Apple `man sandbox-exec`, `sandbox-exec` usage и SDK `usr/include/sandbox.h`:
  deprecated; заголовок говорит, что уже sandboxed процесс получает ошибку.
