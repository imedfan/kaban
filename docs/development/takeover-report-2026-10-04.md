# Отчёт: передача управления и первый инкремент, 2026-10-04

## Резюме

Architect/Analyst, Backend и Frontend работали параллельно как субагенты
gpt-6.1-sol medium; координатор проверял контракты, интеграцию и CI.
Разработка production-кода разрешена новым поручением пользователя. Старые
ограничения team2 на исправления и существующие файлы больше не действуют.
Мержи команда не выполняла. Дизайнерские работы и редизайн не берём;
frontend реализует готовые макеты.

Исправлены Git-policy, identity validation, size overflow, readonly reason и
incident aggregates. Добавлены durable DTO, первый GRDB store, SwiftUI приложение
с mock-клиентом и ограниченная синтетическая проверка Seatbelt. Полный M1/MVP
ещё не готов. Исторический отчёт PR #53 сохраняет состояние предыдущей сессии.

## PR и SHA

| PR | HEAD | Base |
|---|---|---|
| [#54](https://github.com/imedfan/kaban/pull/54) | `e190ccb90af8c293204778efe5cca9c62640a42f` | `main` |
| [#55](https://github.com/imedfan/kaban/pull/55) | `2153382306adf9818d0bec53609bf739f3c2583d` | `main` |
| [#56](https://github.com/imedfan/kaban/pull/56) | `398d2cc77b6050b011163b6d93eb2613c2a28a38` | `main` |
| [#57](https://github.com/imedfan/kaban/pull/57) | `df1949eefa325bee3fa08dbb67e997bafd37f78f` | `codex/kit-git-policy-fixes` |
| [#58](https://github.com/imedfan/kaban/pull/58) | `4029e9a66503669052197ccc6ade49cee5124fe1` | `codex/kit-identity-size-readonly-fixes` |
| [#59](https://github.com/imedfan/kaban/pull/59) | `2f3593cb185b10461d58459cd35555cf9200c579` | `main` |
| [#60](https://github.com/imedfan/kaban/pull/60) | `9e8224ab22142c9ee1d0dc5ff9953ffad4cc373a` | `main` |


## Решения и проблемы

| Issues | Решение / реализация |
|---|---|
| #9 | answerHuman только на agent-стадии; команды остальных видов зависят от состояния |
| #10 | Любая правка .kaban агентом — incident/rollback; продолжение только явной командой человека |
| #11 | Execution WIP/run slots отделены от human admission capacity; лимит не выталкивает уже допущенные задачи |
| #12 | Пустой root diagnostic path означает весь pipeline.yaml; #19 обновлён, прежний skip снят |
| #13 | Экспериментальный deny-default профиль и 41-case probe в #60; production isolation не заявлена |
| #14 | Durable TaskDetail collections и initial settings в #56; default decoding только у новых массивов |
| #23/#24/#25 | Git option parsing и foreign-ref protections в #54 |
| #30/#36/#37 | CRLF до trim, readonly_violation, saturation больших MB в #57 |
| #44 | ProjectSummary authoritative; глобальный счётчик суммирует все проекты, #55 |

Issues остаются открытыми до принятия связанных PR. `Fixes` связывает закрытие
с мержем. Уточнение спецификации не означает, что scheduler/incident executor
уже реализованы. Новых известных дефектов после общей проверки не осталось;
ниже перечислены незавершённые функции и проверки.

Общая проверка выявила шесть нарушений прежнего required-field контракта
TaskDetail: исправлено в #56, прежние humanRequests/suspiciousFiles/acceptedFiles
остаются обязательными. Linux CI обнаружил неподдерживаемый GRDB 7.4.0:
в #58 выбран официальный GRDB 7.11.1 со Swift 6.1 и upstream Linux configuration.
В интерфейсе убран жёстко заданный размер 5 МБ; подпись отсылает к лимиту политики.

## Что проверено

Временный checkout объединяет код #54–59 и 12 файлов прежних Team2 tests/fixtures
из восьми test-веток. На macOS 27.0.1 / Xcode 27:

- SwiftPM: **272 tests, 0 failures, 0 skips**, с KABAN_SCENARIOS=Scenarios/M1.
  По targets: Protocol 49, Kit 157, BoardCore 60, DaemonCore 6.
- Unsigned Xcode build приложения на объединённом коде: **BUILD SUCCEEDED**.
- Seatbelt synthetic probe: **41/41** на macOS 27.0.1, четыре positive controls
  и 37 denial assertions с успешными unsandboxed baselines.
- Все новые code PR имеют зелёные Linux/macOS checks на перечисленных HEAD.
  macOS job исторически optional: проверяли фактический результат, а не только
  общий зелёный статус workflow. В #59 job также собирает приложение.

Логи сохранены в /private/tmp/kaban-takeover-context: combined-final-tests.log,
combined-app-build.log и final-pr-ledger.json. Эти временные файлы не входят в Git.
Документальные уточнения после тестов не меняли tested source tree.

## Что не сделано

- Полный daemon/XPC/kabanctl, fake driver, scheduler, worker и живой Cursor/MCP.
- Wire snapshot/details из store, durable incidents/grants и их транзакционные
  projectUpdated, настройки и прочие части M1.
- Полная frontend приёмка макетов, все действия/редакторы, доступность, dark tokens,
  drag-and-drop, уведомления и подпись/нотаризация.
- Seatbelt на целевой macOS 26, live runtime/build/network, hardlinks,
  inherited descriptors и race attacks. Нет утверждения о production isolation.

## Публикация Google Drive после восстановления подключения

Все шесть актуальных исходных файлов обновлены по прежним IDs. Перед записью
полное содержимое каждого совпало с сохранённым original по SHA-256; после
записи совпало с обновлённой Git-версией. Папки, имена, ссылки и права доступа
сохранены, отдельные старые файлы-версии не изменены. Architecture/acceptance
находятся в #56, frontend plan в #59, backend plan в #58, spec/decisions — в #61.
Нативный исторический checklist team2 не редактировался; новый порядок работы
описан в документах takeover. Публикация документов не означает мерж кода.
План инкремента, очередь PR и этот отчёт опубликованы в
[Drive/development](https://drive.google.com/drive/folders/1blNW9iIIyUs4kgR70MNcjtlWf7hKkpve).

## Вопросы и следующий шаг

Новых продуктовых вопросов, блокирующих следующий M1-инкремент, нет.
Подключение Drive восстановлено, публикация завершена.
Следующая вертикаль: полный snapshot/details,
идемпотентный outbox worker и fake pipeline, затем scheduler/XPC.
Frontend продолжает этап 2 из [плана](first-increment.md).

## Как проверить и принять

Следовать [порядку PR](merge-order.md), проверяя актуальные SHA/CI. Для stacked
#57/#58 после принятия родителя поменять base на main и повторить CI.
Команда сама ничего не мержит. При изменении main повторить интеграцию.

Для SwiftPM нужен Swift 6.1+ и SQLite headers на Linux:

```sh
KABAN_SCENARIOS=Scenarios/M1 swift test
xcodebuild -project Kaban.xcodeproj -scheme Kaban \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/kaban-review-app \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
python3 -B spikes/backend/probe-protected-paths.py \
  --report /tmp/kaban-protected-report.json
```

Команды приложения и probe становятся доступны после принятия #59/#60.
Синтетический probe не является запуском полного spike6.
