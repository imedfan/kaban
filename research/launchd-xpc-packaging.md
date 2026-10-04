# T4 — launchd, SMAppService и XPC: памятка к спайкам 3/4

Проверено 2026-10-04. Kaban A v0.11.22 §2/§5/§6.2/§12/§14:
user LaunchAgent, подписанный клиент, Codable, уведомления первоначально из менюбар-приложения.
Ни сервис, ни разрешения, ни системные настройки в ходе исследования не менялись.
Все идентификаторы ниже — placeholders `com.example.kaban`, заменить согласованными IDs.

## Что известно точно

SMAppService управляет helper внутри основного app bundle на macOS 13+.
LaunchAgent регистрируется для текущего пользователя; `register()` bootstraps его
сейчас и на последующих logins, с учётом разрешения пользователя. Ошибку регистрации
нужно показать; `enabled` означает eligible to run, не доказательство успешного XPC.
[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice),
[register](https://developer.apple.com/documentation/servicemanagement/smappservice/register()),
[status](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/notregistered).

Plist лежит в Contents/Library/LaunchAgents, BundleProgram — путь относительно app.
Не копировать его вручную в ~/Library/LaunchAgents при этом workflow.
[Migration](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).
Apple DTS показывает helper в Contents/MacOS и переход daemon→agent изменением
директории plist и SMAppService API; это подходит для предложенной структуры.
[DTS Getting Started](https://developer.apple.com/forums/thread/802443).

```text
Kaban.app/
  Contents/
    Info.plist                       # app ID com.example.kaban
    MacOS/
      Kaban                          # SwiftUI + menu bar
      KabanDaemon                    # user agent, без daemonize/fork-away
      KabanGitShim                    # nested signed executable
    Library/LaunchAgents/
      com.example.kaban.agent.plist
    Resources/                       # данные, не секреты/run tokens
```

Минимальный draft plist для demand-start Mach service (не production policy):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.kaban.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/KabanDaemon</string>
  <key>MachServices</key><dict>
    <key>com.example.kaban.daemon</key><true/>
  </dict>
</dict></plist>
```

Label, plist filename, Mach name могут отличаться, но каждый параметр должен
совпасть со своим consumer. BundleProgram обязан существовать и быть executable.
Apple DTS показывает эту форму с MachServices; пример у него daemon, адаптация к
agent следует отдельной инструкции выше.
[DTS Mach-service example](https://developer.apple.com/forums/thread/799910).

Для Kaban scheduler должен работать без открытого окна: demand-only plist это
не доказывает. На спайке сравнить запуск при login и после закрытия UI; выбрать
RunAtLoad/KeepAlive policy вместе с recovery/backoff. Не daemonize процесс: launchd
управляет lifecycle. Архивная Apple guide описывает demand запуск и crash-throttling;
актуальные ключи сверить с локальным `man launchd.plist`.
[launchd guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).

## XPC из SwiftUI и подпись пира

SMAppService.agent(plistName:) + register()/status в UI; listener в KabanDaemon
advertises `com.example.kaban.daemon`, client использует XPCSession(machService:).
`xpcService:` — другой механизм, не имя этого MachService. Имя должно быть в
доступном bootstrap; session init throws при недоступном сервисе. User agent
не использует `.privileged` system-daemon bootstrap.
[XPCSession machService](https://developer.apple.com/documentation/xpc/xpcsession/init(machservice:targetqueue:options:incomingmessagehandler:cancellationhandler:)-l3rz),
[privileged scope](https://developer.apple.com/documentation/xpc/xpc_connection_mach_service_privileged).

На macOS 26 использовать XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)
на обеих сторонах: listener принимает Kaban app ID; клиент ожидает daemon signing ID.
Same-team без identifier шире нужного client allowlist — это вывод для Kaban,
а не изменение A §5. Requirement проверяет Apple-issued signing identity;
ad-hoc подпись не проверяет release-путь. Не доверять PID как идентичности бинаря.
[team requirement semantics](https://developer.apple.com/documentation/xpc/xpc_peer_requirement_create_team_identity),
[XPCListener requirement initializer](https://developer.apple.com/documentation/xpc/xpclistener).

Если requirement задаётся setter, session создаётся inactive, затем requirement,
затем activate(); повтор setter — programming error. Default session активна сразу.
[setPeerRequirement](https://developer.apple.com/documentation/xpc/xpcsession/setpeerrequirement(_:)),
[inactive](https://developer.apple.com/documentation/xpc/xpcsession/initializationoptions/inactive).

**Совместимость:** локально read-only проверен Apple SDK Xcode **27.0 / 27A266a**:
`usr/lib/swift/XPC.swiftmodule/arm64e-apple-macos.swiftinterface` строки 553–579,
694–714 объявляют XPCPeerRequirement, listener/session requirement API macOS **26.0+**.
Это не проверка SDK Xcode 26. Baseline Package.swift min macOS15: нужен availability
branch с эквивалентной безопасной проверкой либо решение поднять minimum для UI.
Не обещать, что новый requirement API доступен на 15; API choice для fallback — вопрос
спайка, не повод ослабить listener. Копию системного SDK в репозиторий не добавляли.

SwiftUI updates доставлять на MainActor; XPC callback queue и UI actor не тождественны.
После cancellation переподключение ограничено backoff, затем getSnapshot/subscribe
по A §5; transport не обещает exactly-once domain effects. Codable wire type decode,
protocolVersion, commandId dedup, журнал и resync тестируются отдельно от Mach lookup.

## Команды чтения и ожидаемый результат на mbp

Подставить путь готового spike app. Эти команды не регистрируют/перезапускают сервис.

```sh
TASK_APP='/path/to/Kaban.app'
TASK_LABEL='com.example.kaban.agent'
TASK_UID=$(id -u)
xcodebuild -version
sw_vers
plutil -lint "$TASK_APP/Contents/Library/LaunchAgents/$TASK_LABEL.plist"
file "$TASK_APP/Contents/MacOS/KabanDaemon"
codesign --verify --deep --strict --verbose=2 "$TASK_APP"
codesign -d -r- "$TASK_APP/Contents/MacOS/KabanDaemon"
launchctl print "gui/$TASK_UID/$TASK_LABEL"
log show --last 10m --style compact --predicate 'subsystem == "com.example.kaban"'
```

Ожидание: plist OK; Mach-O архитектура правильная; signature valid; job после
регистрации через spike UI найден в GUI domain; до регистрации print может отказать.
Логи сохранять только своего subsystem с commandId/seq/errors, без env/auth tokens.
Не запускать resetbtm, bootstrap/bootout, killall или sudo в рамках этой памятки.

## Что проверить на маке и записать в фикстуры

1. В отдельном spike app, действиями Артёма: status до register, result/error после,
   enabled/requiresApproval/notFound, отрицательный case отсутствующего BundleProgram.
   Записать OS/Xcode/SDK, bundle IDs, path, NSError domain/code, redacted launchctl.
2. XPC hello Codable DTO → reply; один unsigned/ad-hoc/wrong-team/wrong-ID клиент
   должен быть отклонён до domain handler. Та же проверка сервера клиентом.
   Записать accepted/rejected + cancellation error и requirement, без cert private keys.
3. Закрыть окно и менюбар spike UI по отдельности, login/logout и controlled agent crash
   только тестового PID; проверить scheduler lifecycle, reconnect, snapshot/replay/resync.
   Записать PID/start, seq до/после, count процессов — без чтения других jobs.
4. Проверить Xcode26 SDK compile availability для macOS15 и26; минимум проекта не менять.
5. Уведомления: сначала baseline menu bar app с user authorization, затем bundled agent
   при закрытом UI. Записать getNotificationSettings, request/add error, delivered banner,
   foreground delegate path, click→task. Вручную проверить disabled notifications/Focus.

UNUserNotificationCenter документирован для app/app extension; он управляет authorization
и доставкой, delegate нужен до окончания launch. Это **не доказательство**, что plain
agent executable в bundle может надёжно отправлять уведомления и открывать задачу.
Точный helper identity/authorization и lifecycle — цель спайка4; рабочий fallback
архитектуры — menu bar app. Ни разрешения, ни System Settings нами не изменялись.
[Notification center](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter),
[delegate lifecycle](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/delegate).

Fixtures future: `spikes/T4/<os-build>/registration.json`, `xpc-auth.json`,
`reconnect.json`, `notifications.json`, `launchctl-redacted.txt`. Это предложенный
каталог для Артёма, не созданные результаты. Plist syntax проверен локально;
регистрация/XPC/notification smoke не запускались. Уверенность высокая для bundle/API,
средняя для packaging strategy, неизвестная для spike4 agent notifications.
