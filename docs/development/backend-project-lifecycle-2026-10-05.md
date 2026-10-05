# BE-02: lifecycle локальных проектов

Инкремент `codex/backend-project-lifecycle` от `origin/main` `6508caa`
(принят BE-01, PR #71). Реализует UC-01 и missing-folder часть UC-14;
применение/наблюдение изменений pipeline и настоящий executor следуют в BE-03–06.

## Поведение

`KabanStore.execute` принимает `addProject`, `removeProject`, `relinkProject`,
`listBranches`, `detectGates`, `recheck(project)`. Capabilities отмечает production
support; optional `CommandCapability.scopes` ограничивает `recheck` значением
`project`. Проверка runner остаётся недоступной. Старые capabilities без scopes
декодируются; неверный тип известного поля отклоняется обычным Codable.

Регистрация проверяет рабочий Git-репозиторий, канонический root и локальный main.
Симлинк на root и linked worktree с тем же canonical common Git directory считаются
повторным подключением. Другая базовая ветка даёт `base_branch_required` с
`params.baseBranch=main`. Ветка пользователя не переключается. Existing pipeline
читается из committed `main:.kaban/pipeline.yaml`, независимо от текущего checkout.

Явный автор проверяется без fallback. Без него один раз читается обычный git config
репозитория/пользователя/системы. CR/LF/NUL проверяются до trim; `identity_required`
возвращает missing/invalid и только найденные корректные поля. Автор хранится в
SQLite, mascot seed по умолчанию равен projectId. Ошибки preflight не создают
project, intent или `.kaban/`; отказы мутаций имеют durable replay receipt.

Без YAML, при malformed/semantic-invalid YAML, invalid UTF-8 или превышении лимита
проект хранит задачи в entry queue. Если entry невозможно определить, источник
состояния явно публикует невалидную Backlog-only storage projection, issues и
`no_pipeline`/`pipeline_invalid`. Версия валидного pipeline — SHA-256 точного YAML;
у невалидного PipelineSummary.versionHash=nil. Отсутствующий runner не запрещает
регистрацию или создание Backlog. Apply/reload pipeline ещё недоступны.

Branch listing читает local refs; gates предлагает команды по committed build
дескрипторам Swift, Maven, Gradle, Rust, Go, npm. Эти команды не выполняются и не
устанавливаются в pipeline автоматически: их подтверждает пользователь.

## Шаблон и транзакционная граница

Создание шаблона требует checkout main и отсутствия существующих/индексированных
правок `.kaban/`. Иначе `template_checkout_required`/`template_conflict`; можно
подключить проект без шаблона. Шаблон включает YAML и три stage skills; моделей
по умолчанию нет, поэтому источник публикует pipeline_invalid. При регистрации
hasUncommittedEdits сравнивает рабочую .kaban/ с main; clean/process/smudge filters,
external diff и textconv отключены. Дальнейшее наблюдение этих правок — BE-03.

Git plumbing использует отдельный temporary index, parent main и только известные
файлы `.kaban/`. `commit-tree` требует явного автора. Git objects подготавливаются
до durable intent; refs/index/worktree на этом шаге не изменяются. Затем v4
`project_operation` резервирует commandId, projectId, canonical path/common Git dir
и сохраняет commit/base/blob IDs. CAS update-ref не перезаписывает concurrent main.
Файлы устанавливаются через anchored openat/O_NOFOLLOW и exclusive link; существующий
файл не перезаписывается. В пользовательский index добавляются отсутствующие записи
шаблона; остальные staged/unstaged/untracked файлы сохраняются.

Все Git/FS операции идут вне SQLite transaction через hardened DaemonGit argv/env:
без hooks/fsmonitor, inherited GIT_* и shell; stdout/time bounded, stderr не раскрывается.
Шаблонный commit не включает пользовательские dirty файлы и не меняет ветку checkout.
При git_race/conflict регистрация отказывает и освобождает reservation, сохраняя
пользовательские файлы. Git commit может уже существовать при отказе установки файлов;
он не откатывается скрыто. Повторная регистрация прочитает committed main.

Project record/path, projectAdded/pipelineApplied/stageLoad/settings flags и wire
receipt фиксируются одной SQLite transaction. При DB failure после Git commit intent
остаётся. Startup/original-envelope retry сверяет commit/ancestry, сохраняет более
новые пользовательские commits/правки и завершает регистрацию без второго commit.
Новый main перечитывается перед окончательной регистрацией. Missing/temporary failures
оставляют intent для восстановления; это не обещание exactly-once внешнего процесса.
Host writer lease допускает один runtime на БД; команды одного store сериализуются.

## Папка, relink и удаление

Host проверяет папки на startup и каждые две секунды background timer. Unchanged
наблюдение не создаёт событий. Missing folder или `.git` дают projectUpdated с
availability=missing и correlated scheduler flags, сохраняя task states/details.
Relink проверяет новый Git root/main/duplicate identity и атомарно меняет путь того же
projectId. Настройки, задачи, история и автор сохраняются. Pipeline replacement и
наблюдение ручных правок main относятся к BE-03.

Remove логически архивирует проект. В одной транзакции все нетерминальные задачи
отменяются с keepBranch=true, устаревшие runnable effects supersede, сохраняются kill,
expire-grants и cleanup/archive effects; затем projectRemoved скрывает проект/tasks/
pipeline/loads из snapshot. Project row, task details/runs/feed и receipts остаются в
SQLite; details по известному taskId доступны после reopen. Пользовательский root
никогда не удаляется. Повторное подключение root создаёт новый projectId.

Физический kill/archive/cleanup выполняется будущим executor BE-05/06. Сейчас host
не запускает процессы, а production effects не допускаются в deliverFake. Клоны
не удаляются фальшивым acknowledgement. Production scheduler/start/transitions пока
заблокированы до BE-04; create/edit/priority/cancel/details/project metadata работают.
Bounded fake registration не заменяет production record и не расширяет validator.
BoardProjection удаляет stageLoad вместе с projectRemoved; authoritative add events
передают начальную загрузку стадий.

## Проверки

- macOS full package: 358 tests, zero failures; Linux Swift 6.1: 356, zero failures.
- ProjectLifecycleTests: 14 интеграционных сценариев на настоящих временных Git repos:
  preflight/identity params; dirty template; malformed/missing/valid-main pipeline;
  branch/gate queries; canonical/link-worktree duplicates и concurrent replay;
  folder observer/relink; removal/history/late result; DB rollback/recovery; CAS race;
  symlink conflict и recheck receipt atomicity. Legacy suites проходят без fixture rewrite.
- Real daemon/CLI smoke проверяет template/dirty checkout, Backlog, gates, живой
  folder timer, relink, removal/history, reopen/replay вместе с прежним transport smoke.
- Unsigned Kaban.app build, context checker и diff check проходят.
- Live timer smoke выявил Swift actor-isolation trap: closure унаследовала main
  actor из entry point. Исправлено явным @Sendable callback; сценарий переименования
  папки в работающем host проходит без рестарта.

App продолжает использовать MockKabanClient; окна/UI-сценарии BE-02 не подключены и
визуально не проверялись. Signed Mach service, launchd, реальный Cursor и физическое
исполнение effect outbox не заявляются. BE-03–20 остаются отдельной незавершённой очередью.
