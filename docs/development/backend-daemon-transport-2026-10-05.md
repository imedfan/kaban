# Backend: daemon transport и kabanctl

База: `origin/main` `cb849f0`, после принятого PR #69 с durable wire-командами.
Ветка: `codex/backend-daemon-transport`. Инкремент добавляет проверяемую командную
границу между процессами. Основное SwiftUI-приложение пока использует mock.

## Реализовано

- `DaemonRequest`/`DaemonResponse` в Protocol оборачивают существующие
  CommandEnvelope/CommandReply, Snapshot и EventEnvelope. Даты на проводе
  используют общий KabanCoding. Legacy DTO и их обязательные поля не меняются.
- `DaemonService` — единый receiver всех adapters. Protocol mismatch, неверный
  запрос, неполная проекция и сбой хранилища дают явные ответы. Текст SQL/internal
  exceptions не попадает в ответ. Storage failure не превращается в успешный ack.
- `KabanStore.journalPage` читает ограниченный пакет и latestSeq одной read
  transaction. Проверяются отрицательный cursor, размер, gap внутри журнала,
  обрезанный prefix и cursor впереди БД. Частичная страница продвигает cursor
  только через последний event. Максимум — 256 events, сообщение — 8 МиБ.
- Durable seq берётся из SQLite AUTOINCREMENT high-water mark. Удаление всех
  events не сбрасывает snapshot seq и не позволяет повторно использовать старые
  номера. Retention policy/автоматическая обрезка ещё не добавлены.
- `DaemonClient` в новом KabanTransport зависит только от Protocol. После
  snapshot клиент читает journal после snapshot.seq: commit между ними не теряется.
  Catch-up идёт пакетами без паузы; live delivery использует polling раз в 200 мс.
  Повтор соединения сохраняет cursor, backoff растёт до 5 с. Resync выдаёт
  replacement snapshot до следующих events. Все проекты идут в глобальном порядке;
  projectIds filter пока не поддержан.
- Команда при connectionLost/timedOut повторяется один раз с исходным envelope
  и commandId; доменный отказ или неверный ответ не запускает слепой retry.
  Состояние клиента меняется только snapshot/events, а не `.ok`.
- Async stream ограничен 512 updates. Медленный потребитель получает
  `bufferOverflow`, сохранив последовательность уже доставленных событий;
  затем он возобновляет подписку от последнего применённого seq. Отмена потока
  останавливает polling/backoff.
- `XPCDaemonListener`/`XPCDaemonTransport` используют Swift XPC на macOS 26.
  Mach service `app.kaban.agent` требует same-Team signature в обе стороны,
  unsigned режима Mach service нет. Request deadline по умолчанию 10 с;
  callback, timeout и cancellation могут завершить continuation только один раз.
- `KabanDaemon` открывает явно указанную БД под эксклюзивной process lease,
  выполняет recovery и обслуживает receiver. `kabanctl` читает snapshot,
  отправляет исходный JSON envelope, читает страницу журнала и watch stream.
  Доменный отказ команды даёт ненулевой exit status и полный typed reply в stdout.

## Локальная проверка без регистрации службы

Подпись, LaunchAgent registration и платные CLI не нужны для development smoke.
`--stdio` использует private pipes дочернего процесса; никакого сетевого listener
или ослабления Mach authentication нет. Один CLI владеет одним development
daemon/DB; параллельные реальные клиенты предназначены для XPC.

```sh
swift build
swift run kabanctl --help
swift run kabanctl --stdio-daemon /absolute/path/to/KabanDaemon --database /tmp/kaban-demo.sqlite snapshot
python3 tools/smoke-daemon-transport.py --bin-dir /absolute/path/to/build/products
KABAN_SCENARIOS=Scenarios/M1 swift test
```

Путь products можно получить `swift build --show-bin-path`; он зависит от build
engine. Каталог SQLite должен существовать. Stdio frames ограничены до чтения
полного сообщения; pipe IO находится на отдельной serial queue. Таймаут/отмена
останавливает дочерний процесс и освобождает reader; для игнорирующего TERM
собственного процесса предусмотрен KILL через 200 мс. Native read используется
для pipes, поскольку FileHandle.read(upToCount:) может ждать заполнения буфера.

## Проверки и границы

macOS: `swift build` и полный `KABAN_SCENARIOS=Scenarios/M1 swift test` прошли:
327 tests, без failures.
Новые transport tests проверяют snapshot/subscription handshake, частичные страницы,
потерянный после commit ответ и exact-envelope retry, ID conflict, retention при
пустом журнале, reconnect/resync, backpressure и invalid requests. Настоящий XPC
через private anonymous endpoint проверяет command correlation/replay, snapshot,
timeout и cancellation. Stdio tests проверяют deadline/cancellation зависшего
child и ошибочный ответ. Process smoke проверяет CLI/daemon reopen/replay,
durable refusal, conflict, catch-up, retention, single writer и malformed input.

Первый полный прогон в sandbox добавлял `git: warning: confstr() ...
DARWIN_USER_TEMP_DIR` в stderr и ломал точные assertions существующих Git tests.
Повтор вне sandbox прошёл; assertions не ослаблялись. Build caches перенесены
в `/tmp` через SWIFTPM_MODULECACHE_OVERRIDE/CLANG_MODULE_CACHE_PATH/--cache-path.

Linux: официальный `swift:6.1` (Swift 6.1.3, aarch64), одноразовый контейнер
с read-only source mount, SQLite headers и отдельной копией исходников.
`swift build`, 325 tests и тот же process smoke прошли. Два XPC tests доступны
только на macOS. Context checker и diff также прошли.

Подписанный Mach service, Team-ID refusal и launchd activation в установленном
бандле ещё не проверены. Private endpoint не доказывает это. Большие snapshot/detail
свыше 8 МиБ требуют отдельной pagination, сейчас получают `response_too_large`.
Unsigned App build прошёл после additive изменений Protocol/Package.swift.
SwiftUI views и основной runtime не менялись; настоящее окно/визуальные состояния
не проверялись. Host не запускает scheduler loop, fake driver, git/Cursor effects,
MCP или quota poller. Production lifecycle и регистрация проектов остаются
следующими этапами; fake registration по-прежнему внутренний API.

Ближайший результат: связать существующий BoardStore/KabanClient с transport,
replacement snapshots и reconnect pending commands, затем production lifecycle
и живой executor. Полный M1/MVP этим инкрементом не объявляется готовым.

API XPC сверены с локальным SDK и первичными источниками Apple:
[XPCListener](https://developer.apple.com/documentation/xpc/xpclistener),
[XPCPeerRequirement](https://developer.apple.com/documentation/xpc/xpcpeerrequirement).
