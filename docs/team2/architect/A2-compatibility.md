# A2 — совместимость Codable

Дата 2026-10-04; baseline `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.
Добавлен только [Team2CompatTests.swift](../../../Tests/KabanProtocolTests/Team2CompatTests.swift).
Sources, Samples, старые тесты/fixtures, Package и CI не изменены.
A = [архитектура v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view),
S = [спека v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view).

10 тестовых методов покрывают все публичные Codable DTO и enum-типы,
включая вложенные enums, typed IDs и CommandID/Seq. Для каждого object DTO:
неизвестный ключ, удаление **каждого** поля, null вместо каждого поля,
проверка documented default/nil либо ожидаемого decode error.
Типы single-value не имеют JSON-полей: неизвестные поля к ним неприменимы;
проверяются неверные enum values / object вместо ID. Helpers без Codable
(KabanCoding, BillingCycle, ModelPoolResolver, HardInvariant, UnknownTag,
Calendar.utc) не считаются DTO и не имеют omission-контракта.

## Покрытые DTO и классификация полей

Список ниже полный. Mandatory — все поля типа, кроме перечисленных
optional/default; точный mandatory inventory задан `fields:` в тестах.
Optional missing и null → nil; default применяется к обоим. Инициализатор
Swift с default argument сам по себе не даёт decode default.

| Типы | Optional поля | Decode default / примечание |
|---|---|---|
| StageDisplay | icon, color | order/collapsed/hidden mandatory |
| StageReturn | — | stage/limit mandatory |
| StageSummary | wip, model, onSuccess, maxAttempts, onFail, onConflict, gitPolicy | gates=[] |
| GitRule | source | неизвестная source-строка → nil; неверный тип throws |
| ConditionalGitRule | — | returnReason/allowed mandatory |
| EffectiveGitPolicy | — | denied/hardInvariants/conditional=[] |
| PipelineSummary | versionHash, defaultReturnStage, projectGitPolicy | gitCommandCatalog=[] |
| ValidationIssue | stageId | params=[:] |
| ProjectSummary | maxRuns, identity | openIncidentCount=0 |
| TaskCard | branch, maxAttempts, model, retryAt | hasAcceptanceCriteria=false; suspiciousFiles mandatory |
| RunSummary | endReason, actualModelName, endedAt, exitCode, logPath, wipRef | countsTowardLimits mandatory |
| SuspiciousFile | pattern | isText=false |
| Incident | runId, resolvedAt | — |
| Snapshot | quota | stageLoad=[]; protocolVersion mandatory, numeric value not rejected by codec |
| StageLoad | wipLimit | — |
| FileBlobRef | — | — |
| AcceptedFile | commandId | by/at mandatory |
| QuotaOptions, McpServerRef | — | init default аргументы не optional wire |
| CommandEnvelope | — | version проверяет transport |
| CommandReply | seq | — |
| CommandError | — | params=[:] |
| GitIdentity | — | string validation outside codec |
| EnvironmentReport | cursorAgentPath, version, gitVersion | — |
| TaskDetail | clonePath | humanRequests/suspiciousFiles/acceptedFiles mandatory несмотря на init=[] |
| FeedItem | runId | kind открытый String |
| EventEnvelope | projectId, commandId | — |
| TaskTransition | runId, note | — |
| SettingsChange | — | — |
| HumanRequest | runId | — |
| HumanAnswer | requestId | — |
| GitDenied, GitGrantCreated, GitGrantDelivered, GitGrantRef, GitGrantRevoked, GitGrantExpired, GitPolicyUpdated | — | Каждый payload проверен отдельно |
| IncidentResolved | commandId | — |
| SuspiciousFilesFound | runId | — |
| SuspiciousFilesAccepted | commandId | — |
| RunnerCheck | reason, version | checkedAt mandatory |
| PipelineDraftValidation | resolved | issues mandatory |
| RunProgress | message | lastActivityAt mandatory |
| ModelInfo | missingSince | needsReview/forbidden mandatory |
| ModelPoolRule | — | — |
| ModelFlag | actual, fallbackModel, lastProbeAt | — |
| QuotaState | cm, om, billingCycleStart, billingCycleEnd | fetchedAt mandatory |
| LogBatch | — | offsets/events mandatory |

## Enum и scalar поведение

Все закрытые raw enums **throws** на `team2_future`: StageKind, GitPreset,
StageCommitter, GitRuleSource, ValidationIssue.Severity, ProjectSummary.Availability,
SuspiciousFile.Rule, IncidentKind, IncidentListState, McpServerRef.Source,
GitGrantDeliveryVia, GitGrantExpiryReason, Actor, ModelPool, ModelPoolRule.Source,
ModelFlag.Reason, SchedulerFlag.Level, RunnerUnavailableReason,
ProjectUnavailableReason, TaskStatus, WaitingHumanReason, QueuedReason,
RetryWaitReason, BlockedReason, RunStatus, RunEndReason.

Custom tagged enums: JournalEvent/EphemeralEvent unknown type → `.unknown(type)`;
known type без data → throws (resyncRequired не требует data).
PolicyScope unknown kind → throws; TaskState unknown status/reason → throws,
включая optional queued reason. SchedulerFlag unknown flag/reason → throws.
Лишние ключи известных tagged enum игнорируются. A §5 требует skip только
неизвестного event type; расширение reasons/flags не объявлено совместимым.

Synthesized enums Command, CommandResult, AgentEvent, RejectTarget,
RecheckScope: unknown case → throws, extra key known case игнорируется.
Все 46 Command payloads проверены с extra вложенным ключом и удалением
каждого аргумента; optional identity/maxRuns/editTask.title/body/grantAttempts/
model/requestId/requestChanges.target/projectIds → nil. Остальные required.
Все 7 AgentEvent cases проверены с extra вложенным ключом и удалением аргументов;
modelName/sessionId/inputTokens/outputTokens/code/durationMs optional.
Для CommandResult/RejectTarget/RecheckScope проверен representative known case
и future case; типы вложенных payload имеют отдельные field tests.

ProjectID, TaskID, RunID, StageID, ModelID, IncidentID, DenialID, GrantID,
HumanRequestID: single string; object `{rawValue,...}` rejected. CommandID
(UUID) rejects invalid UUID, Seq (Int64) rejects string. Protocol version 999
в Snapshot/CommandEnvelope codec принимает; listener обязан сравнивать версию.

## Результаты и ограничения

Filtered: 10 тестов, 0 failures на Apple Swift 6.4, macOS arm64.
Full suite с `KABAN_SCENARIOS=Scenarios/M1`: **195 tests, 0 failures**
(Protocol 42 = прежние 32 + новые 10; Kit 107; BoardCore 46).
Команда (cache и scratch вне проекта, без записи fixtures):

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/kaban-team2-a2-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/kaban-team2-a2-modules \
KABAN_SCENARIOS=Scenarios/M1 swift test \
  --scratch-path /private/tmp/kaban-team2-a2-build \
  --cache-path /private/tmp/kaban-team2-a2-cache
```

Linux Swift 6.0 локально не выполнялся: Docker/service/system не запускались;
портируемость ограничена Foundation/XCTest и swift-tools-version 6.0,
Linux CI должен подтвердить. Нет KnownIssue/XCTSkip: все новые assertions зелёные.
Новых confirmed bugs нет. TaskDetail missing fields остаются [#14](https://github.com/imedfan/kaban/issues/14),
A2 не исправляет и не дублирует их. Неоднородность unknown policy documented
только для journal/ephemeral и GitRule.source; для закрытых enums это observed
контракт, не обещание downgrade-compatible будущих значений. Missing/null
обязательного поля, будущий enum или новый required field могут оборвать
snapshot decode; version negotiation/recovery — вопросы XPC реализации.
