# BE-20: bundle, LaunchAgent и живой клиент

Дата: 6 октября 2026. Ветка `codex/be-20-launch-agent`, worktree `kaban-be20`.
База: принятый BE-19 `d3ba1f7` из PR #90 (включая BE-18 #89). Сам BE-20 ещё не принят.

## Реализация

- Native Xcode helper target использует тот же DaemonMain и Core. Bundle содержит
  `Contents/MacOS/KabanDaemon` и `Contents/Library/LaunchAgents/app.kaban.agent.plist`.
- SMAppService register/status/requiresApproval/unregister/restart доступны из App.
  Изменение хеша helper вызывает unregister/register, БД и проекты не удаляются.
  Ошибка установки отображается отдельно от статуса службы; есть переход в Login Items.
- Штатный клиент подключается по Mach service и использует sessionUpdates:
  authoritative replacement, journal, ephemeral, connection. Команды блокируются
  до окончания синхронизации; `.ok` не меняет карточку и не снимает pending.
  Fixture остаётся только в явном UI QA; developer mode запускает встроенный helper
  через private stdio, с отдельной БД и без установки системной службы.
- DB/Workspaces: `~/Library/Application Support/Kaban`; logs: `~/Library/Logs/Kaban`.
  Каталоги 0700, DB/WAL/SHM/lock/log 0600. Неверный owner и symlink отклоняются.
  Developer data использует суффикс `Development`. launchd/private child получают
  фиксированный PATH, runner проверяется по сохранённому абсолютному пути.
- Один writer lease; перед listener/scheduler выполняется recovery BE-18.
  SIGTERM зарегистрированной службы останавливает listener/observer/scheduler
  и запускает recovery для принадлежащих процессов и durable effects.
- `tools/package-local-app.sh` создаёт реальную ad-hoc подпись с Hardened Runtime,
  проверяет sealed app/helper/plist. Вымышленный Team ID не записывается.
  Apple certificate: same-team + exact signing ID. Личная ad-hoc сборка:
  exact peer signing ID + code-directory hashes из проверенного sealed bundle.

## Проверки и незавершённая приёмка

Unsigned App build и ad-hoc Release packaging прошли. Проверка codesign видит
`app.kaban.desktop` и `app.kaban.agent`, `adhoc,runtime`, TeamIdentifier отсутствует.
Новые tests проверяют отдельные private layouts, исправление permissions,
symlink workspace/log и отказ неподписанному/неверно идентифицированному peer.
Реальный daemon/CLI smoke прошёл. Полный первый прогон: 510 tests, zero failures;
финальный прогон после усиления private-file permissions: 511 tests, zero failures.

Настоящий WindowGroup с embedded stdio daemon прошёл create/edit/pause/resume/cancel
через correlated journal, сохранил Markdown. Светлый снимок:
`/tmp/kaban-be20-live/light.png`. Это проверка UI + настоящей БД, без paid Cursor.
Повторное открытие с сохранённой БД прошло (task/body/journal, seq 23).
QA использовал `-ApplePersistenceIgnoreState YES`, постоянный AppKit UI-state не менялся.
UI smoke PR #91 выявил гонку между применением snapshot и событием `connected`:
проверка могла вызвать create до разрешения команд и затем ждать отсутствующий event.
QA теперь ждёт и snapshot, и connected перед первым действием; assertions команд
сохранены. Таймауты называют конкретный этап. Unsigned rebuild и полный fixture
UI smoke прошли локально (`/tmp/kaban-be20-ci-native-smoke.json`, шесть checks).

Повторные terminal UI QA нестабильны: некоторые запуски не создавали WindowGroup
(runtime/store=nil, windows=0). Тёмный минимальный кадр и error/empty matrix пока не подтверждены.

**SMAppService acceptance пока не завершена.** Реальный register дал
`SMAppServiceErrorDomain / 1 / Operation not permitted`, статус `notFound`.
Журнал smd: `SMAppService target executable must be sandboxed because the app is sandboxed`.
Системная служба не была установлена; не заявляются successful unregister/reboot/requiresApproval.
Архитектура §13 требует работу без App Sandbox, а исходный Xcode App target включает Sandbox.
Автоматическая проверка дважды отклонила его отключение без явного разрешения пользователя.
Sandbox оставлен включённым; точечный Mach lookup entitlement этого ограничения не устраняет.

Apple подтверждает, что sandboxed App не может установить unsandboxed job на macOS 14.2+:
[SMAppService guidance](https://developer.apple.com/forums/thread/802443).
Для завершения требуется согласование настройки App target, затем реальный register/XPC/restart/unregister.
Другая Apple Team identity и reboot не проверены: у пользователя нет Apple certificates,
компьютер в рамках проверки не перезагружался. Ad-hoc подпись не обещает стабильное
системное согласие после обновлений: [Apple signing guidance](https://developer.apple.com/forums/thread/799910).
Production Cursor launch/MCP lifetime, CLI isolation и полная frontend acceptance
сохраняют ограничения прежних инкрементов. BE-20 пока не означает готовность полного MVP.
