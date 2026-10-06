# BE-03: версии и применение production пайплайна

База — `ff74c43` (`origin/main`, BE-02 принят в PR #72). Ветка —
`codex/backend-pipeline-storage`. [PR #73](https://github.com/imedfan/kaban/pull/73)
открыт в main; выполнение отмечено в [очереди задач](backend-mvp-tasks.md).

## Реализованный сценарий

Локальный проект хранит authoritative source из `main:.kaban/`: ref разрешается
один раз, файлы читаются по immutable blob IDs. Валидная версия сохраняет YAML,
полную конфигурацию и assets, включая referenced skills вне `.kaban/` из того же
коммита. Хэш учитывает пути/режимы/байты; unrelated main commit его не меняет.
Лимиты чтения — 1 МиБ YAML, 16 МиБ assets, 1024 файла; symlinks, gitlinks,
special files и unsafe skill paths отклоняются. Git filters/hooks/signers не исполняются;
replace refs не подменяют immutable blob IDs.

Typed `PipelineDraft` связывает точный UTF-8 hash с project/base. Optional
`sourceHash`/`baseSourceHash` различают successive invalid sources, у которых
versionHash=nil; valid legacy drafts используют baseVersionHash. Nullable
baseVersionHash по-прежнему обязателен на проводе. Malformed известные поля
отклоняются, старые fixtures сохранены. Общий validator обслуживает все stage
kinds, модели, graph/returns, gates/hooks, board/workspace/git/suspicious options
и resolved policy; MCP warnings не блокируют apply. Fake exception не расширен.

`updatePipeline` создаёт `.kaban/`-only commit через isolated index, commit-tree
и CAS main под explicit identity; чужие staged/unstaged/untracked файлы сохраняются.
Dirty YAML, отличный и от draft, и от committed base, даёт pipeline_worktree_conflict.
Checkout другой ветки даёт pipeline_checkout_required. Active merge блокирует save;
стадию с нетерминальными задачами нельзя удалить или сменить её kind.

До публикации Git ref сохраняется pipeline_operation. Receipt/версия/journal/
проекция завершаются атомарно; failure после Git commit сохраняет intent, commandId
и project reservation. Startup или повтор команды завершают эффект без второго
коммита. Index lock удерживает intent; concurrent main до CAS даёт git_race.
При recovery более новый descendant main сохраняется, accepted version остаётся
в истории БД даже при последующем invalid main. Более поздние editor/staged edits
не заменяются. Existing YAML никогда не перезаписывается; отсутствующий создаётся
эксклюзивно. UI должен сначала записать exact draft согласно архитектуре §3.1;
при command-only save старый файл остаётся dirty, committed версия уже новая.

Startup, recheck и observer раз в две секунды подхватывают ручные main commits и
working changes. Committed issues определяют unavailable/pipeline_invalid;
uncommittedIssues показывают отдельную проверку рабочего YAML. Невалидный working
draft не останавливает valid main. Invalid main сохраняет lanes занятых задач,
блокирует новое binding/stage exit; valid reload автоматически снимает флаг.

RunSpec хранит immutable pipeline/assets/identity/effective policy/return reason,
effect payload связывается с ним через optional runSpecId. Следующий start binding
берёт новую valid версию. Текущий run может завершиться по старым правилам; его
stage exit при invalid main/pending apply сохраняется в pipeline_deferred и
возобновляется после valid apply/reload, включая полный startup recovery;
уже завершённая попытка при restart повторно не запускается. Удаление пустой downstream стадии не
оставляет завершившийся run без маршрута: exit использует current successor,
execution settings остаются из старого RunSpec. WIP shrink публикует фактическую
загрузку выше нового лимита, не вытесняя текущие задачи. BoardProjection удаляет
устаревшие loads исчезнувших колонок.

## Проверки

- `KABAN_SCENARIOS=Scenarios/M1 swift test` на macOS: 377 тестов, 0 failures;
  полный прогон повторён после исправления Git completion. Startup recovery
  также проверен отдельно тремя затронутыми recovery tests.
- Linux Swift 6.1.3/aarch64: `swift build`, полный прогон 375 тестов и daemon/CLI
  process smoke на окончательном коде. Все проверки прошли.
- macOS: `swift build` и daemon/CLI process smoke; invalid template → valid apply,
  replay/reopen, dirty index, live manual invalid/fix reload без restart host,
  missing/relink/remove/history и single writer.
- Unsigned `xcodebuild -project Kaban.xcodeproj -scheme Kaban -destination
  'generic/platform=macOS' ... ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build`:
  BUILD SUCCEEDED. SwiftUI файлы не менялись, визуальная приёмка не заявляется.
- `python3 tools/check-project-context.py` и `git diff --check` прошли.

CI на `b55e3d3`: оба Linux jobs и context checks прошли; macOS прошёл unsigned App
build и 377 tests, но smoke оборвал addProject через 15 секунд. Исправление
сохраняет прежние дедлайны: LocalGitRepository ждёт termination notification
вместо polling `Process.isRunning`, project completion повторно не читает уже
полученный source/dirty state. После правки macOS full suite (377), Linux full
suite (375), build и process smoke прошли. Git-интеграционные сценарии выполняются
заметно быстрее. На `c15e8ff` Linux build/tests/smoke прошли, macOS CI прошёл
build, unsigned App build, 377 tests и ранее падавший process smoke.
PR #73 принят в main как `bc9abc9`; оставшиеся дублирующие jobs ожидали runners.

17 PipelineLifecycleTests покрывают общий validator, exact draft/source races,
only-.kaban commit, working/staged preservation, crash/recovery/index lock,
поздний invalid descendant, outside skill snapshots, replace refs/filters/signers,
RunSpec/WIP shrink/active stage deletion, deferred stage exit и startup. Два
Protocol tests проверяют новые optional поля и invalid nil-base binding; nearby
BoardProjection test проверяет удаление loads только изменённого проекта.

## Границы

Production scheduler/start и внешнее исполнение Cursor/gates/git merge здесь не
включены: BE-04–08 добавляют эти пути. Проверки immutable invocation/completion
seed-ят сохранённые production runs, а fake effect проверяется настоящим fake
store path. Это не запуск Cursor. App остаётся на MockKabanClient; unsigned build
проверяет совместимость Protocol/BoardCore, новые SwiftUI экраны и настоящее окно
не проверялись. LaunchAgent registration/подпись/paid CLI не запускались.
Observer использует polling; FSEvents остаётся целевым механизмом.

История версий и RunSpec добавлены migration v5; старые rows/payloads не переписаны.
Внешний Git эффект не обещает exactly-once process: восстановление сверяет
committed факты и не перезаписывает более позднюю пользовательскую работу.
