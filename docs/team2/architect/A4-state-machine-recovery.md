# A4 — автомат и восстановление после сбоев

2026-10-04; baseline `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.
Источники: [архитектура v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view)
§3.2–3.3, §6.3, §8.2, §8.5, §10;
[спека v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view)
UC-04–12, UC-25;
[TaskMachine.swift](../../../Sources/KabanKit/StateMachine/TaskMachine.swift),
[TaskMachineTypes.swift](../../../Sources/KabanKit/StateMachine/TaskMachineTypes.swift).
Матрица фиксирует **поведение чистого автомата baseline**, затем сравнивает с требованиями.
Effect не доказывает успешный git/SQLite/process operation; KabanDaemonCore отсутствует.
Код, старые тесты, Scenarios, CI и существующие документы не изменялись.

## Все статусы × domain events

Q=queued, R=running, G=gating, T=retry_wait, H=waiting_human, P=paused,
B=blocked, D=done, C=cancelled — все 9 статусов A §3.2.
I=ignored; F=rejected invalid_state; `=`=тот же status, effects возможны.
Условия kind/reason/phase/runId раскрыты после таблицы; пустых клеток нет.
TaskEvent.human разложен во второй матрице. StartBlock разложен на два условия.

| TaskEvent | Q | R | G | T | H | P | B | D | C |
|---|---|---|---|---|---|---|---|---|---|
| start | S | I | I | S | I | I | I | I | I |
| startBlocked(wipFull) | Q:wip_full | I | I | I | I | I | I | I | I |
| startBlocked(quota/modelFlag) | Q:reason | I | I | Q:reason | I | I | I | I | I |
| completeStage | K | G:gates | K | K | K | K | K | I | I |
| returnToStage | K | RT | K | K | K | K | K | I | I |
| requestHuman | K | H:question | K | K | K | K | K | I | I |
| runEnded | I | E | I | I | I | I | I | I | I |
| modelMismatch | I | H:model_substituted | I | I | I | I | I | I | I |
| gitDenialLimit | I | H:git_denials | I | I | I | I | I | I | I |
| daemonRestarted | I | T:daemon_restart | RG | I | I | I | I | I | I |
| probeFinished | I | I | I | PR | I | I | I | I | I |
| gatesPassed | I | I | GP | I | I | I | I | I | I |
| gatesFailed | I | I | GF | I | I | I | I | I | I |
| resultChecked | I | RC | RC | I | I | I | I | I | I |
| mergeConflict | I | I | MC | I | I | I | I | I | I |
| mainDirty | I | I | MD | I | I | I | I | I | I |
| mainCleaned | I | I | I | I | I | I | G:fastForward | I | I |
| merged | I | I | M | I | I | I | I | I | I |

- S: agent → R с явной model; исчерпанные attempts → H:retries_exhausted,
  maxRuns → H:run_limit, нет явной модели → I. gate → G:gates, merge → G:rebase,
  human → H:review, terminal → D, queue → вход onSuccess. WIP/квоту/backoff
  проверяет исполнитель до start; чистый автомат не обеспечивает это самостоятельно.
- Вход в target: terminal → D, human → H:review, прочие → Q; нет target/onSuccess
  → H:incident. На входе resets attempts/context стадии.
- K: текущий runId в R разрешён; lastRunId finished → I, иной runId → F.
  Клетки в R также требуют currentRunId; runEnded/modelMismatch/gitDenialLimit
  с несовпавшим currentRunId → I.
- RT: разрешённый returnsTo → вход target, bounce +1; превышен лимит → H:bounce_limit,
  общий лимит возвратов → H:run_limit; неразрешённый target → F.
- E: crash/stall/wall → WIP save+rollback, списать attempt, T соответствующей причины
  либо H:retries_exhausted; noFinalCall → T:no_final_call либо исчерпание;
  rateLimit/runnerAuth/silentExit → T без списания; usageExhausted/modelUnavailable
  → Q с соответствующим флагом. Покрыты все RunFailure cases.
- RG: G сохраняется; phase gates → runGates, resultCheck → runResultCheck,
  rebase → startMerge, fastForward → fastForwardMerge; nil phase считается gates.
- PR: только T:silent_exit + silentExitPending. clean → списанная attempt,
  T:crash или H:retries_exhausted; rateLimit → T:rate_limit;
  usageExhausted/modelUnavailable → Q с флагом. Остальные T → I.
- GP: gates/rebase → G:resultCheck + runResultCheck, другие phases → I.
- GF: agent+gates → T:gate_failed либо H:retries_exhausted;
  gate+gates → onFail либо H:bounce_limit; merge+rebase → onConflict либо
  H:conflict_limit; другие kind/phase → I.
- RC: incident допустим в R (kill run) → H:incident. Иначе только G:resultCheck:
  clean → следующий stage, agent emit commitStage, merge → G:fastForward;
  suspicious nonempty → H:suspicious_files, пустой set → clean;
  incident → H:incident; readOnlyChanges → T:gate_failed/исчерпание,
  второй strike → H:invalid_result. Остальные R/G → I.
- MC: только merge+G:rebase → writable agent onConflict с conflict+1,
  либо H:conflict_limit. MD: G:fastForward → B:main_dirty; иначе I.
  M: G:fastForward → вход onSuccess; иначе I.

Если stage отсутствует, приоритетная ветка :80 разрешает human move/cancel;
прочие human-actions → not_found, domain events → I. D/C проверяются прежде stage:
human-actions F, автоматические события I. Retry timer приходит как start.

## Все статусы × human commands

HumanAction.reject разделён на cancel/stage; Fₛ=stale_suspicious_files.

| Command / HumanAction | Q | R | G | T | H | P | B | D | C |
|---|---|---|---|---|---|---|---|---|---|
| answerHuman | F | F | F | F | AH | F | F | F | F |
| approve | F | F | F | F | AP | F | F | F | F |
| requestChanges | F | F | F | F | CH | F | F | F | F |
| reject(stage) | F | F | F | F | CH | F | F | F | F |
| reject(cancel) | C | C | C | C | C | C | C | F | F |
| pauseTask | P | P | P | P | F | F | F | F | F |
| resumeTask | F | F | F | F | F | Q | F | F | F |
| moveTask | MV | MV | MV | MV | MV | MV | MV | F | F |
| retryStage | F | F | F | F | RS | F | F | F | F |
| cancelTask | C | C | C | C | C | C | C | F | F |
| acceptSuspiciousFiles | Fₛ | Fₛ | Fₛ | Fₛ | AS | Fₛ | Fₛ | Fₛ | F | F |

- AH: agent+H(any reason) → Q той же стадии, answered priority, resumeSession,
  humanAnswer в prompt; exhausted attempts +1. Suspicious set не принимается.
  Другие kind → F. AP: human+H:review → onSuccess; иначе F.
- CH: существующий writable agent target текущей/предыдущей стадии либо defaultReturnStage;
  nil default → F, неизвестный stage → not_found, readOnly/вперёд → F.
  requestChanges не принимает suspicious set; reject(stage) принимает;
  human возврат не расходует лимиты. Исходный kind код не ограничивает.
- MV: существующий нетерминальный target (включая read-only); kill current run,
  вход target; неизвестный stage → not_found, terminal → F.
- RS: H(reason != review), grant nil/≥0; Q своей стадии, добавить попытки при необходимости,
  принять suspicious set, invalidResultStrikes=0. Иначе F.
- AS: H:suspicious_files и равный path/blob set → G:resultCheck + accept/recheck effects;
  новый run не создаётся. Остальные H/несовпавший set → Fₛ.
- C: killLiveRun, expireGitGrants(task_cancelled), cleanupClone(keepBranch).
  Архивацию kaban/archive/<task-id> выполняет исполнитель. Applied human-actions
  обнуляют runsSinceHuman; эффекты не доказывают успешную доставку/очистку.

Публичные Command шире TaskEvent; остальные команды не реализованы как handlers:

| Группа | Применимость по status / граница знания |
|---|---|
| editTask | A §5 разрешает Q/H/P, остальным invalid_state; кода handler нет |
| setPriority | UC-11 влияет на следующий выбор; final-state applicability не задана |
| setModelOverride | настройка задачи/стадии; status allowlist не задан |
| getTaskDetail/getRunHistory/listIncidents | чтения; listener/not_found отсутствует |
| allowGitOnce/revokeGitGrant/addDenialToPolicy | grants/policy, не непосредственный status event; доставка по A §8.3 |
| pauseAll/resumeAll/pauseProject/resumeProject/resumeAfterRateLimit | флаги, текущие runs доигрывают, status задач не paused |
| createTask | создаёт новую Q в Backlog, существующего status нет |
| Проекты/pipeline/models/quota/MCP/environment | отдельный lifecycle, не TaskEvent; handler отсутствует |

Эта группировка не объявляет команды no-op. JournalEvent taskUpdated/taskTransitioned
— результат перехода; ephemeral флаги/квота/прогресс не являются прямым TaskEvent.

## Пробелы требований и вопросы владельцу

| Вопрос | Доказательство | Предложение, не правка |
|---|---|---|
| Terminal move | A §3.3 «в любую стадию» vs TaskMachine.swift:580 terminal forbidden; S UC-11 forward через gates запрещён | Явно отделить drag policy от command policy; terminal guard может быть правильным, подтверждённым багом это не объявляется |
| retry/pause applicability | A §3.3 retryStage из H vs :587 исключает review; pause :565 только Q/R/G/T, в A/S точный allowlist не указан | Явно перечислить запрещённые H reasons/B и идемпотентность повторного pause/cancel |
| requestChanges source kind | A §3.3 human/gate/merge, :544 разрешает любой H с допустимым target | Согласовать agent+H действия с UC-25 и перечислить контракт |
| readonly reason | A §3.2 и S UC-04 readonly_violation; :390 chargeAttempt(gateFailed) | Ссылка основной команде для дедупликации существующих findings, без исправления |
| Recovery всех проектов | A §10 result check для всех; daemonRestarted :273 I для Q/T/H/P/B/D/C | Назвать project reconciliation обязательным отдельным проходом, не подменять TaskMachine event |
| Recovery G phases | A §10 перезапустить gates, :282 учитывает четыре phases | Определить durable phase, checkpoint/effect ordering и повторяемость каждого effect |

D/C намеренно терминальны. Q/T/H/P/B имеют выходы через start/timer/human/resume/mainCleaned;
структурных тупиков нет при доступных стадиях/человеке/исправлении main. Если stage исчез,
остаются move/cancel. Если defaultReturnStage nil, CH откажет, остаются move/cancel
или answer/retry на agent. Status без phase/reason недостаточен для recovery.

## Каждая точка падения коммита (§6.3)

Git ref и SQLite не одна транзакция. `?` — недостающий durable contract; имена intents
ниже предложены, в baseline storage их нет. TaskEffect doc: после persist state,
«journal first». :406–407 emit commitStage и сразу enter next stage, commit ack отсутствует.

| Падение | Что обнаружит recovery | Ожидаемый результат / пробел |
|---|---|---|
| До agent commit, живой/осиротевший run | DB R, pid/start, dirty clone | kill group; WIP save+rollback; T:daemon_restart без списания A §10 |
| Agent commit создан, run не завершён | R, новый clone HEAD | T:daemon_restart; ? last stage commit vs agent commit для rollback |
| complete_stage принят, gates идут | G:gates, strict dirty tree/summary | G, повтор gates; не откатывать dirty clone как orphan R |
| Gates clean, check не завершён | G:resultCheck, diff/refs | G, повтор result check; incident/suspicious → соответствующий H |
| Check clean, commit ещё не вызван | commitStage effect, state уже next-stage | ? Следующий run запрещён до durable commit ack; в enum нет pending-commit phase |
| Commit начался, ref старый | lock/index/объекты, dirty tree | ? Проверить живого владельца lock и HEAD; не удалять lock вслепую |
| Commit durable, DB checkpoint старый | новый HEAD, старая DB | ? Распознать intended parent/tree, принять existing commit без duplicate safety commit |
| DB next-state durable, commit не выполнен | Q/H следующей стадии, старый HEAD | ? Reconcile pending intent до dispatch next-run; иначе проверенный diff теряется |
| Commit+DB/event durable, UI ответ потерялся | seq в журнале, старый UI seq | durable state/replay; CommandID dedup требуется A §5/§9, handler отсутствует |
| refs_snapshot ещё старый | легитимный ref, stale snapshot | ? Сверить own intent до классификации incident |

Предложение: durable intent(task/run/stage, old/new HEAD, expected tree) до effect;
ack до next-stage publication/dispatch; replay по refs/tree, а не только commit message.
Strict summary/artifacts сохранить до gates. Process-kill и power-loss проверять отдельно:
process-kill не доказывает fsync. Реализацию storage/DaemonGit здесь не меняем.

## Каждая точка падения слияния (§8.5)

| Падение | Что обнаружит recovery | Ожидаемый результат / пробел |
|---|---|---|
| До fetch, head очереди выбран | задача merge, main старый | G:rebase, повторить подготовку; ? durable ownership очереди |
| Во время/после fetch | task ref уже мог появиться, main старый | ? Согласовать ref с refs_snapshot до проверки результата, повтор после проверки source |
| Temp clone создан, до rebase | temp clone, исходный task ref | G:rebase; ? имя/ownership и cleanup temp clone |
| Во время rebase | metadata/partial commits/conflicts | ? Abort/reconstruct с intent; A описывает abort при конфликте, crash отдельно не определён |
| Rebase готов, gates не закончены | candidate, base SHA, G:rebase | повторить gates; изменение main требует rebase/recheck, не ff устаревшего кандидата |
| Conflict/red gates, до durable return | files/output, ещё G, counter неизвестен | onConflict, conflict+1 ровно раз, Human Review снова; ? dedup/fencing |
| Checks clean, до ff | candidate/main old SHA | G:fastForward; проверить expected old main и result перед ff |
| ff отказал из-за human dirty main | main старый, human uncommitted files | B:main_dirty/merge_blocked; сохранить правки, retry автоматически после cleanup человеком |
| ff main уже сдвинул, DB ещё G | main=candidate, старая DB | ? Распознать выполненный ff, durable merged/event ровно раз; не false incident |
| Human сдвинул main после ff, DB ещё G | descendant/иная история candidate | ? Ancestry+expected SHA reconciliation, не откатывать законную работу человека |
| DB D/event durable, clones ещё есть | main содержит результат, D | отложенный идемпотентный cleanup, не rerun |
| Cleanup завершён, D не durable | source clone исчез, DB G | ? Запретить cleanup до durable completion; восстановить по intent/main |

Предложение: один durable merge intent на проект, candidate/base SHAs, checkpoint
fetch/rebase/gates/ff/completion; compare-and-swap main; completion/event до cleanup.
Повторяемость gates явно определить: их команды могут иметь побочные эффекты.
Статус G сам по себе не позволяет решить, что повторять безопасно.

## Что проверено и что осталось

Покрыты 9 статусов, все 18 TaskEvent cases, 10 HumanAction cases и условные payloads.
Matrix guards/switch прочитаны в baseline; document diff проверен. Тесты к документу
не добавлялись. Fault injection требует отсутствующего daemon/storage; таблицы —
ожидаемые требования и вопросы, не результаты crash-экспериментов.
Высокий приоритет: commit/DB ordering, ff без durable D, stale refs_snapshot при fetch/ff,
cleanup до completion. Средний: повтор gates, conflict dedup, manual-action allowlist.
Новые issues не создавались: координатор дедуплицирует findings с #9–11/#14 и отчётами команды.
Уверенность высокая для baseline matrix, средняя для требуемых recovery outcomes,
низкая для атомарности отсутствующего исполнителя. Реализация recovery не заявлена.
