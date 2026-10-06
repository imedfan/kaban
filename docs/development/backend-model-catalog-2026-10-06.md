# BE-14: каталог моделей и проверка подмены

Дата: 6 октября 2026. Ветка `codex/be-14-model-catalog`, база — `codex/be-07-cursor-driver`
(`c49de37`, [PR #79](https://github.com/imedfan/kaban/pull/79), ещё не принят в main).
Очередь — [backend MVP](backend-mvp-tasks.md).

## Реализовано

`ModelCatalogMatcher.parseListModels` принимает только непустые строки `id<TAB>name`. Любая другая непустая строка, включая ошибку аутентификации, `@`, token, secret или key, возвращает nil и не заменяет сохранённые строки. Форма `--list-models` установленного CLI не снята. `auto` сохраняется с `forbidden` и не попадает в `listModels`. Новая незапрещённая строка начинает с `needsReview`.

`observe` требует ровно одну незапрещённую строку запрошенного id. Фактическое display name должно совпасть с именем этой строки и не быть именем другой строки: тогда `.confirmed`. Если имя равно ровно одной другой строке, это `.substituted`. Пустое, неизвестное, неоднозначное имя и повтор id дают `.unconfirmed`. Совпадение не выдумывается.

Каталог и override лежат в миграции `model_catalog_v11`. Override — таблица `model_override`, не поле версии pipeline, поэтому он не меняет другие задачи и не сбрасывается `bindPipelineForStart`. `setModelOverride` отвергает `auto`, пустое значение и placeholder. Пользовательское правило пула снимает `needsReview` у совпавших id. Встроенное `composer-*` по-прежнему даёт cm, остальное — om. Удаление правила не трогает встроенное.

Исчезнувший из нового текста id получает `missingSince` и флаг `unavailable` только для себя. Вернувшийся id снимает только `unavailable`. `refreshCatalogIfDue` идёт следом за проверкой runner и только если задан `--cursor-agent`. Без пути процесс не запускается. Непонятный текст сдвигает `nextRefreshAt` на сутки и не стирает строки. `CursorRunner.listModelsText` вызывает только `--list-models`, не `-p`.

`observeModelInit` — вход store для `system/init`. Неподтверждённое имя пишет одну строку feed `model_unconfirmed`; повтор того же commandId её не дублирует. Известная подмена вызывает `modelMismatch`: run завершается `model_substituted`, попытка не списывается, `completeStage` уже завершённый run не превращает в успех. Флаг `raiseModelFlag` пишется в той же транзакции `apply` и не уходит во внешний outbox. `killRun` остаётся внешним эффектом. Стадия, чей разрешённый model id имеет флаг, не стартует. Очередь по-прежнему смотрит на первую agent-стадию.

`listModels`, `refreshModelCatalog`, `setModelOverride`, `setModelPoolRule`, `removeModelPoolRule` и `clearModelFlag` поддержаны в `DaemonService`. Команды, которые запускают процесс или пишут сами, выходят из `execute` до общей транзакции. Несовпадение версии протокола сохраняется как wire reply.

## Границы

Платный `-p` не запускался. Установленный CLI не залогинен, поэтому остановка до первого инструмента не наблюдалась. Этот пункт приёмки остаётся открытым. Игнор `completeStage` после подмены — поведение store, а не эксперимент над процессом CLI.

Живой stream не подключён к `observeModelInit`: process-pass запускает переданный `--runner`, не Cursor. `--approve-mcps` не передаётся. Числовая квота не выдумывается. Exactly-once внешнего процесса нет.

## Проверки

- `ModelCatalogTests`: confirmed, substituted, неизвестное и неоднозначное имя, пустое имя и отсутствующий id; ошибка аутентификации и строка без таба дают nil; `auto` в каталоге forbidden; YAML `model: auto` даёт `model_auto_forbidden`.
- `ModelCatalogStoreTests`: `auto` отвергается валидатором и `setModelOverride`; override задачи `a` не меняет задачу `b` и переживает reopen. Неизвестное имя остаётся `model_unconfirmed`, повтор commandId не добавляет вторую строку, каталог не пополняется выдуманной строкой. Известное другое имя оставляет `waitingHuman(.modelSubstituted)`, не списывает попытку, `completeStage` не делает run успешным, флаг requested/actual/fallback переживает reopen. Исчезнувший id блокирует только свои стадии; `clearModelFlag` снова разрешает старт.
- Остановка до первого инструмента не проверялась: установленный CLI не залогинен, платный `-p` не запускался.
- Два запуска `KabanDaemon --stdio --cursor-agent` на одной временной БД с локальным скриптом сохраняют один и тот же каталог: `composer-2` (cm, needsReview) и `gpt-5` (om, needsReview). `auto` отсутствует и в payload, и в `listModels`. Скрипт не запускает `-p`. Строка без таба в проверке runner не становится строкой каталога и добавляет один вызов `--list-models`, когда срок каталога наступил.
- macOS: полный `KABAN_SCENARIOS=Scenarios/M1 swift test` — 427 tests, 0 failures (Transport 23, Protocol 64, Kit 169, DaemonCore 105, Board 66).
