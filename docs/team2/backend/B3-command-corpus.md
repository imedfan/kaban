# B3 — корпус git-команд

Дата: 2026-10-04. База `origin/main` (`1d647ea`). Только новые тест и JSON,
production-код и существующие тесты не менялись; команды агента не запускались.

## Покрытие и границы

`Fixtures/team2/git-deny.json`: 166 уникальных строк, из них 150 активных
статических deny, 9 контекстных требований shim, 5 matcher gaps и 2 вопроса force-алиасов.
`git-allow.json`: 64 разрешённых контроля. У каждой строки свой ожидаемый
инвариант (у allow — null), слой и короткое обоснование.
`Team2GitPolicyCorpusTests.swift` проверяет публичные
`hardInvariant(for:)`, `normalize`, `EffectiveGitPolicy.allows`.

Ожидания основаны на спеках v0.8.24 §1.5 и архитектуре v0.11.22 §§8.2, 8.4.
Принудительно широкая project allowlist проверяет, что запрет задаётся
инвариантом, а не отсутствием команды в пресете. Пробелы размножаются для
проверки normalizer. deny включает push/remote/config/tag, force/short clusters,
clean без dry-run, удаление/переименование refs, main и формы origin/main,
refs/heads/main, main~n/main^. Контроли включают аргументы после `--`, пути
`main`/`--force`, обычный `-f` в grep/blame/ls-files, чтение и own-branch writes.
Регистр ref не меняется нормализацией; Git подкоманды чувствительны к регистру.

Вход API начинается с подкоманды, без executable `git`: это нормализованная
политика, не shell parser. `-c`, `-C`, `--git-dir`, .kaban writes, refspec fetch,
notes/worktree targets включены как явно deferred требования будущего
`/git/check`/Seatbelt. Для `kaban_dir` статического matcher по архитектуре нет.
Метаданные deferred строк проверяются, но запрет не выдаётся за реализованный.
Разрешённый статический контроль не утверждает, что он разрешён конкретному
run: цель ref, clone boundary и конкретный preset остаются другим слоем.
Пустые/невалидные uppercase Git команды не используются как доказательство
обхода. Произвольные shell строки с quotes/tabs требуют токенизации shim.

## Воспроизведённые пропуски

Публичный API для всех семи строк возвращает `hardInvariant=nil`; широкая
политика возвращает `allows=true`:

| Команда | Ожидаемый id | Наблюдение реального Git 2.55.0 |
|---|---|---|
| `checkout -Btask1` | foreign_refs | Существующая task1 сброшена на текущий HEAD |
| `switch -Ctask1` | foreign_refs | Существующая task1 сброшена на текущий HEAD |
| `branch --del other` | foreign_refs | other удалена; Git принимает сокращение |
| `branch --mov other renamed` | foreign_refs | other переименована |
| `rebase --onto=main HEAD~1` | foreign_refs | Git принимает equals-форму цели main |
| `checkout --for` | force | Dirty tracked файл восстановлен в base |
| `switch --discard-changes task` | force | Dirty tracked файл восстановлен при switch |

Attached-аргументы с цифрами обходят `shortCluster`:
`Sources/KabanKit/Git/GitPolicy.swift:120` требует только буквы во всём body.
Сокращения не совпадают с exact `--delete`/`--move` (строка 94).
`--onto=main` не распознаётся `namesMain` (строки 122–125).
Force-алиасы не совпадают с `--force*`/short -f (строки 77–78).
Последние два случая дополнительно требуют решения, должна ли политика
запрещать все семантические force-алиасы или только формы из списка §1.5.
Это статические пропуски/вопросы контракта, а не доказательство обхода
реальной границы проверки результата демоном (§8.2.4).

Real Git проверки шли только в disposable `/private/tmp` репозиториях с
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, no terminal prompt,
синтетическими автором и email. Исходный репозиторий и refs не менялись.
Для attached reset: создать base commit, ветку task1 на base, active с новым
коммитом; выполнить строку из таблицы, сравнить `rev-parse task1` до/после.
Для force: сделать tracked файл dirty; выполнить строку и проверить base.
Для сокращений: создать other и проверить список refs после команды.

[Issue #23](https://github.com/imedfan/kaban/issues/23): attached reset arguments;
[issue #24](https://github.com/imedfan/kaban/issues/24): branch abbreviations и
вопрос force-алиасов; [issue #25](https://github.com/imedfan/kaban/issues/25):
`--onto=main`. Три focused теста условно skipped только пока matcher gap
воспроизводится. Основные 150 deny/64 allow проверки всегда активны.
Force-алиасы остаются question metadata без assertion ожидаемого matcher:
спека задаёт буквальный префикс `--force*`, а не все семантические эквиваленты.

Финальная проверка Mac (Apple Swift 6.4, Darwin arm64): полный
`KABAN_SCENARIOS=Scenarios/M1 swift test` — 191 тест (32 protocol + 113 kit +
46 board), 0 failures, 3 focused skips; прежние 185 зелёные. Kit: 19,051 с,
все модули: 19,185 с; incremental build: 0,94 с. Project-temp caches,
outer sandbox escalation для real-git tests; Linux здесь не запускался.
JSON decode/уникальность/metadata, normalizer и `git diff --check` проходят.
