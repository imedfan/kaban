# T5 — Developer ID и нотаризация: чек-лист для mbp / M5

Дата проверки первичных источников: 2026-10-04. A v0.11.22 §13/§15:
Hardened Runtime + Developer ID, без App Sandbox; nested daemon и KabanGitShim.
Документ — план для Артёма. Не создавались сертификаты/ключи, не читались auth secrets,
не подписывались бинарники, не отправлялось ПО Apple, системные настройки не менялись.

## Что известно точно

Developer ID Application подписывает app/исполняемый код; Developer ID Installer
нужен для installer pkg, не для обычного app/ZIP. Account Holder создаёт сертификат
на сайте/Xcode; cloud-managed доступ может быть делегирован отдельно. Проверить
действующее членство/роль и наличие private key у identity до release.
[Certificates / role / creation](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

Notary service требует валидные подписи всех исполняемых компонентов, подходящий
Developer ID, secure timestamp, Hardened Runtime для app и command-line targets.
`get-task-allow` нужно убрать из distribution. Accepted submission не заменяет
runtime-тест самого продукта.
[Notarization preparation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[common failures](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

Runtime exceptions — отдельные entitlements, не обязательный комплект. Для SwiftUI,
нативного daemon и git shim нет доказанной необходимости allow-jit/unsigned-memory/
disable-library-validation: начать без них и обосновать конкретный failing feature.
Hardened Runtime не равен App Sandbox; sandbox отсутствует по решению A §13.
[Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime).

Подписать nested код изнутри наружу; main app последней. Entitlements присваиваются
каждому main executable отдельно, не библиотекам. У nonbundled daemon/shim свой
устойчивый signing identifier; не применять codesign --deep для подписания.
Restricted entitlement (например keychain-access-groups) может потребовать
distribution provisioning profile и app-like helper bundle; это отдельное решение,
не автоматическое требование plain KabanDaemon.
[Signing and profiles](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

## Что сделать в понедельник в Apple Developer / Xcode

1. Артём проверяет Team/Account Holder, agreements/membership; выбирает новые устойчивые
   app/daemon/shim IDs одной команды. Не публиковать private key, p12 или пароль.
2. Certificates → + → Developer ID Application, CSR → download/install в Keychain,
   либо Xcode Settings → Accounts → Manage Certificates. Проверить, что identity
   содержит private key. Installer создавать только если выбран pkg.
3. В будущих app/helper targets: одинаковая Team, Release signing, Hardened Runtime;
   app/helper entitlements review по отдельности, distribution get-task-allow отсутствует.
   Не добавлять restricted capabilities без profile и сценария использования.
4. Копировать daemon/shim в bundle до финальной подписи app; plist/data в правильные
   locations T4. Не менять sealed bundle после подписи. Проверить executable architectures.
5. Product → Archive → Organizer → Distribute App → Direct Distribution / Developer ID,
   дальнейший notarization/export workflow согласно доступному экрану Xcode26.
   Если «Distribute Content», проверить Archive Products и SKIP_INSTALL у nested targets.
   [Archive/export](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
   [distribution methods](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).
6. Зафиксировать exact Xcode26 build/SDK/OS и выбранный экран workflow. Локально сейчас
   read-only определён Xcode27.0 (27A266a), **не Xcode26 smoke**. Текущие Apple страницы
   не доказывают точный UI конкретного Xcode26 patch; командный путь ниже снимает это.

Baseline SwiftPM ещё не содержит app Xcode target/Release bundle: команду archive
нельзя объявлять готовой для main. После появления проекта проверить scheme и
`xcodebuild -help`; ExportOptions.plist взять из ручного корректного export, не
выдумывать устаревшие значения method. Ни Package.swift, ни Xcode project здесь не менялись.

## Подготовка команд на mbp (без system xcode-select)

Все команды ниже запускает Артём на готовом export-кандидате; путь/identity placeholders
заменяются локально. Переменная DEVELOPER_DIR действует только в данной shell.
Сначала сохранить экспорт-копию в новом рабочем каталоге, не подписывать исходный app.

```sh
export DEVELOPER_DIR='/Applications/Xcode_26.app/Contents/Developer'
xcodebuild -version
sw_vers
xcrun --find notarytool
xcrun notarytool submit --help
xcrun stapler --help
security find-identity -v -p codesigning
```

Ожидание: Xcode26 build, доступные инструменты, valid Developer ID Application identity.
Вывод identity содержит реальные имя/Team ID: перед fixtures редактировать локально,
не переносить raw account details в публичный PR.

Если Xcode уже подписал правильный export, повторная ручная подпись не нужна.
Иначе этот порядок для **копии** app без дополнительных frameworks:

```sh
TASK_APP='/path/to/export-copy/Kaban.app'
TASK_SIGNING_ID='Developer ID Application: <Team Name> (<Team ID>)'
codesign --force --sign "$TASK_SIGNING_ID" --timestamp --options runtime \
  --identifier 'com.example.kaban.daemon' "$TASK_APP/Contents/MacOS/KabanDaemon"
codesign --force --sign "$TASK_SIGNING_ID" --timestamp --options runtime \
  --identifier 'com.example.kaban.gitshim' "$TASK_APP/Contents/MacOS/KabanGitShim"
codesign --force --sign "$TASK_SIGNING_ID" --timestamp --options runtime "$TASK_APP"
codesign --verify --deep --strict --verbose=2 "$TASK_APP"
codesign -d --verbose=4 "$TASK_APP/Contents/MacOS/KabanDaemon"
codesign -d --entitlements :- "$TASK_APP/Contents/MacOS/KabanDaemon"
codesign -d --entitlements :- "$TASK_APP/Contents/MacOS/KabanGitShim"
codesign -d --entitlements :- "$TASK_APP"
```

Ожидание: валидные подписи и timestamp, runtime flag для каждого executable, согласованный
TeamIdentifier; release get-task-allow отсутствует. Если компоненту нужны entitlements,
согласовать отдельный plist и добавить `--entitlements /path/to/component.entitlements`
в **его** signing command. Main app entitlements не копируются всем helpers.
Вложенные frameworks/XPC bundles, если появились, подписываются раньше зависимых executables.
[Inside-out verification guidance](https://developer.apple.com/library/archive/technotes/tn2206/).

## Notarytool и stapler

Credential profile создаётся Артёмом интерактивно (пароль не вставлять в shell/history/PR):

```sh
xcrun notarytool store-credentials 'KabanNotary' \
  --apple-id '<your-apple-id>' --team-id '<your-team-id>'
```

Команда попросит app-specific password и сохранит его в Keychain. App Store Connect
API key — отдельный supported вариант, private key не в репозитории.
[Interactive profile](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

Рекомендуемый первый контейнер — ZIP одного app. Shell blocks sequential, переменные
из предыдущих шагов сохранить; `TASK_OUT` — новый каталог вывода, в нём нет прежних артефактов.

```sh
TASK_OUT='/path/to/new-release-output'
mkdir -p "$TASK_OUT"
ditto -c -k --keepParent "$TASK_APP" "$TASK_OUT/Kaban-upload.zip"
xcrun notarytool submit "$TASK_OUT/Kaban-upload.zip" \
  --keychain-profile 'KabanNotary' --wait --output-format json > "$TASK_OUT/submission.json"
```

Продолжать только после status **Accepted**, не по факту upload/id. Из submission.json
скопировать id в TASK_SUBMISSION_ID; при Invalid получить log и исправить указанную
signature/entitlement/build проблему, затем пересобрать/подписать и отправить заново.

```sh
TASK_SUBMISSION_ID='<id-from-submission-json>'
xcrun notarytool log "$TASK_SUBMISSION_ID" --keychain-profile 'KabanNotary' \
  "$TASK_OUT/notary-log.json"
xcrun stapler staple "$TASK_APP"
xcrun stapler validate "$TASK_APP"
ditto -c -k --keepParent "$TASK_APP" "$TASK_OUT/Kaban-release.zip"
codesign --verify --deep --strict --verbose=2 "$TASK_APP"
spctl --assess --type execute --verbose=2 "$TASK_APP"
```

Ожидание: Accepted, log без critical issues (проверить warnings тоже), stapler validation
успешна, spctl accepted / Notarized Developer ID. Финальный ZIP заново содержит stapled app.
ZIP нельзя staple напрямую; standalone daemon/shim тоже не поддерживают standalone staple,
поэтому доставлять внутри notarized app/container. У контейнера DMG/flat pkg supported
staple есть; все code/container подписи изнутри наружу, notarize outermost standard container.
[Notary workflow / container limits](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[distribution containers](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Проверка на маке и fixtures

- Download финального ZIP/DMG через браузер на другом test Mac/чистом test account;
  обычный Finder запуск с Gatekeeper, online и offline после stapling. Не снимать
  quarantine и не отключать Gatekeeper для положительного теста.
- Проверить agent registration/XPC mutual signature, daemon start без shell PATH,
  запуск cursor-agent и shim с runtime protections, менюбар notification click→task.
  Accepted notarization не гарантирует эти функции. Структура app и signing IDs
  должны совпасть с T4; unsigned/ad-hoc client negative case обязателен.
- Проверить обновление app той же Team/IDs, service status/reconnect, отсутствие
  лишнего helper процесса; helper cleanup/status тестировать отдельным spike app.
- Записать OS/Xcode26/SDK, git SHA, architecture, export settings, redacted signature
  diagnostics, submission status+id, notary log, stapler/spctl результат и app smoke.
  В fixtures не должны попасть аккаунты/ключи/профиль Keychain/private credentials.

Apple рекомендует тестировать конечный distribution artifact, по возможности на
другом Mac, чтобы development environment не исказила результат.
[Final artifact testing](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
Fixtures proposal: `spikes/T5/<os-build>/manifest.json`, `notary-redacted.json`,
`stapler.txt`, `gatekeeper.txt`, `smoke.json`. Это ожидаемые записи, не результаты.
Уверенность высокая для certificates/sign/notary sequence, средняя для точного Xcode26 UI.
Не выполнено: реальный signing/notarization/clean-Mac smoke, потому что нет release app
и эта задача исследовательская. M5 релиз не заявлен готовым.
