# B4 — DaemonGit / GitIdentity: real Git edge cases

Дата: 2026-10-04. Ветка: `team2/backend-b4-daemon-git`. База: `origin/main`, `1d647ea`. Источники: spec v0.8.24 UC-01 и архитектура v0.11.22 §8.2; checklist §6.2 B4. Уверенность: высокая для проверенных случаев.

Добавлен только `Tests/KabanKitTests/Team2DaemonGitEdgeTests.swift`: 26 XCTest-методов (25 проходят, один условно пропущен по issue). Ни production-код, ни существующие тесты, Package.swift, CI и Scenarios не изменены. Коммит локальный; PR/публикацию координирует root.

## Покрытие

| Группа | XCTest-методов | Проверяемое ожидание |
|---|---:|---|
| Отсутствует identity, system/global/local, includeIf match/mismatch | 6 | Нормальный Git config при регистрации, precedence по отдельным ключам |
| Пустое local не fallback, tabs/spaces в name/email, оба пустые | 4 | `missing`, найденное trimmed поле, стабильный порядок `name,email` |
| LF name, CR email, оба invalid, mixed missing/invalid | 4 | `invalid`, отклонённое значение отсутствует в params |
| NUL explicit и CRLF repository/explicit | 2 | NUL не достигает argv; CRLF обязан быть invalid (#30) |
| Unicode trimmed, commit author против system/global/local | 2 | Реальные author/committer равны explicit identity |
| Spaces/newline/Unicode filenames, non-UTF-8 tree entry, binary blob | 3 | NUL-delimited пути и побайтовое сохранение Data |
| Detached HEAD, unborn status/initial commit | 2 | Git работает без ветки/истории; explicit identity для commit |
| Gitlink plumbing и initialized local submodule с пробелами | 2 | Режим 160000, `.gitmodules`, чистый status после daemon commit |
| Hostile inherited repository locators | 1 | Identity читается из заданного repo |

Итого 26 методов. CRLF-метод содержит три пары полей (name, email, оба только CRLF с spaces/tabs), каждая проверяется через repository и explicit input. Эти шесть проверок не считаются отдельными XCTest-методами.

Репозитории удаляются после теста; helper создаёт отдельный temporary root, HOME и TMPDIR указывают в него, GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM — в синтетические файлы там же. PATH фиксирован `/usr/bin:/bin`, окружение Git не наследуется. DaemonGit получает собственный whitelist/hardening; GitIdentity читает только синтетические config layers. Личный Git config не читается и не изменяется. Для submodule fixture только подготовительный вызов Git имеет `-c protocol.file.allow=always`; daemon после подготовки выполняет add/commit/read с обычным hardening, без сетевых обращений.

APFS не позволяет создать имя с invalid UTF-8 bytes. Поэтому переносимый тест создаёт объект через `hash-object --stdin`, tree через `mktree -z` с именем `raw-` + FF FE и проверяет `ls-tree --name-only -z` как Data. Проверено хранение/чтение Git tree; Linux checkout такого имени этим тестом не проверяется. Существующие valid UTF-8 filenames действительно создаются в filesystem.

## Подтверждённый баг

[Issue #30](https://github.com/imedfan/kaban/issues/30), major: CRLF в имени/почте принимается, хотя UC-01 требует `invalid` для переноса строки. Минимальное воспроизведение в isolated repo: `git config user.name` со значением `A\r\nB`, `git config user.email a@example.com`; `resolveForProject(explicit:nil, repositoryPath:...)` возвращает identity вместо `identity_required` с params `invalid=name,email=a@example.com`. Причина: `GitIdentityRequired.check` сравнивает Swift Character с отдельными CR/LF, тогда как CRLF — одна графема.

Regression использует spec-ожидания; условный XCTSkip с URL возникает только если хотя бы один CRLF input принят. После исправления skip исчезнет, ожидаемые params будут проверены. Неправильная классификация error или неожиданный тип error не замаскированы skip. Production не исправлялся. Исходный failing assertion сохранён во внешнем журнале `/private/tmp/kaban-team2-context/B4-repro.log`.

## Проверка

macOS arm64, Git `2.55.0`; Apple Swift `6.4` (swiftlang-6.4.0.34.1).

```sh
KABAN_SCENARIOS=Scenarios/M1 \
CLANG_MODULE_CACHE_PATH=/private/tmp/kaban-team2-module-cache \
swift test --disable-sandbox \
  --cache-path /private/tmp/kaban-team2-spm-cache \
  --config-path /private/tmp/kaban-team2-spm-config \
  --security-path /private/tmp/kaban-team2-spm-security
```

Для реального Git команда запускалась вне внешней sandbox: внутренний `--disable-sandbox` сам по себе не снимает внешнюю sandbox. Полный прогон: exit 0, Protocol 32 теста, KabanKit 133 (1 skip #30), BoardCore 46; 0 failures. B4 отдельно: 26 методов, 25 pass и 1 conditional skip. Журнал полного финального прогона: `/private/tmp/kaban-team2-context/B4-full-final.log`. Linux не запускался в этой macOS-сессии; зелёный Linux должен подтвердить CI. Никакие настройки системы или установки не менялись.

## Неопределённое и ограничения

Spec не определяет filesystem encoding путей, binary/submodule/unborn/detached internals: их проверки подтверждают Git byte preservation и готовность аргументов DaemonGit к обычной работе; новые требования продукта не вводят. Не выявлено отдельного спорного ожидания продукта, требующего XCTExpectFailure. Вопрос Backend: нужен ли отдельный Linux checkout non-UTF-8 entry и поддержка recursive submodule операций? Пока проверены tree/index/commit и initialized local submodule.
