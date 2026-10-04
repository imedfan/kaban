# A3 — XPC / Codable справочник

2026-10-04; baseline `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.
Источник wire — Sources/KabanProtocol; требования:
[A v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view) §3/§5/§8/§12,
[S v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view).
Примеры: [reference-samples.json](../../../Tests/KabanProtocolTests/Fixtures/team2/reference-samples.json).
Ключ примера совпадает с типом; `command.<case>` / `<EventType>.<tag>` — отдельные case-примеры.
Все примеры синтетические DTO, не обещание domain-валидности или существования IDs.
[Team2ReferenceSamplesTests](../../../Tests/KabanProtocolTests/Team2ReferenceSamplesTests.swift) проверяет **каждый** из 175 ключей: decode → encode → decode с типизированным равенством.

Сущности сериализуются object; типизированные IDs — string; Command/CommandResult/AgentEvent
имеют Swift synthesized shape `{case:{labels...}}`, unlabeled payload — `_0`.
Journal/Ephemeral — `{type,data}`. Даты — ISO8601 milliseconds; decoder допускает без milliseconds.
`?` ниже = optional, missing/null → nil; `=...` = **decode** default при missing/null.
Остальные поля mandatory, даже если Swift init имеет default argument.
Лишние object-ключи игнорируются. protocolVersion=1; проверка версии — XPC listener,
не JSONDecoder. snapshot/command version999 может декодироваться.

## DTO: поля, типы, обязательность и defaults

| Тип и код; ключ примера | Поля (все) |
|---|---|
| [ProjectSummary](../../../Sources/KabanProtocol/Entities.swift#L3) | id:ProjectID; name:String; path:String; baseBranch:String; availability:Availability; weight:Int; maxRuns:Int?; mascotSeed:String; openIncidentCount:Int=0; identity:GitIdentity? |
| [TaskCard](../../../Sources/KabanProtocol/Entities.swift#L39) | id:TaskID; projectId:ProjectID; title:String; stageId:StageID; state:TaskState; priority:Int; branch:String?; attempt:Int; maxAttempts:Int?; runsSinceHuman:Int; bounceByReason:[String: Int]; overlapsWith:[TaskID]; unusedGitGrants:Int; model:ModelID?; retryAt:Date?; suspiciousFiles:[SuspiciousFile]; hasAcceptanceCriteria:Bool=false; updatedAt:Date |
| [RunSummary](../../../Sources/KabanProtocol/Entities.swift#L98) | id:RunID; taskId:TaskID; stageId:StageID; number:Int; status:RunStatus; endReason:RunEndReason?; requestedModel:ModelID; actualModelName:String?; countsTowardLimits:Bool; startedAt:Date; endedAt:Date?; exitCode:Int32?; logPath:String?; wipRef:String? |
| [SuspiciousFile](../../../Sources/KabanProtocol/Entities.swift#L125) | path:String; rule:Rule; pattern:String?; sizeBytes:Int64; isText:Bool=false; blob:String |
| [Incident](../../../Sources/KabanProtocol/Entities.swift#L156) | id:IncidentID; projectId:ProjectID; taskId:TaskID; runId:RunID?; kind:IncidentKind; rolledBack:[String]; openedAt:Date; resolvedAt:Date? |
| [Snapshot](../../../Sources/KabanProtocol/Entities.swift#L172) | protocolVersion:Int; seq:Seq; projects:[ProjectSummary]; pipelines:[PipelineSummary]; tasks:[TaskCard]; schedulerFlags:[SchedulerFlag]; modelFlags:[ModelFlag]; quota:QuotaState?; openIncidentCount:Int; stageLoad:[StageLoad]=[] |
| [StageLoad](../../../Sources/KabanProtocol/Entities.swift#L208) | projectId:ProjectID; stageId:StageID; wipUsed:Int; wipLimit:Int? |
| [QuotaState](../../../Sources/KabanProtocol/Quota.swift#L4) | cm:Double?; om:Double?; billingCycleStart:Date?; billingCycleEnd:Date?; fetchedAt:Date |
| [LogBatch](../../../Sources/KabanProtocol/AgentEvent.swift#L15) | runId:RunID; fromOffset:Int64; nextOffset:Int64; events:[AgentEvent] |
| [StageDisplay](../../../Sources/KabanProtocol/Pipeline.swift#L8) | icon:String?; color:String?; order:Int; collapsed:Bool; hidden:Bool |
| [StageReturn](../../../Sources/KabanProtocol/Pipeline.swift#L19) | stage:StageID; limit:Int |
| [StageSummary](../../../Sources/KabanProtocol/Pipeline.swift#L26) | id:StageID; name:String; kind:StageKind; display:StageDisplay; wip:Int?; model:ModelID?; readOnly:Bool; returnsTo:[StageReturn]; onSuccess:StageID?; maxAttempts:Int?; gates:[String]=[]; onFail:StageReturn?; onConflict:StageReturn?; gitPolicy:EffectiveGitPolicy? |
| [GitRule](../../../Sources/KabanProtocol/Pipeline.swift#L94) | rule:String; source:GitRuleSource? |
| [EffectiveGitPolicy](../../../Sources/KabanProtocol/Pipeline.swift#L111) | preset:GitPreset; allowed:[GitRule]; denied:[GitRule]=[]; hardInvariants:[String]=[]; conditional:[ConditionalGitRule]=[]; committer:StageCommitter; readOnly:Bool |
| [ConditionalGitRule](../../../Sources/KabanProtocol/Pipeline.swift#L157) | returnReason:String; allowed:[GitRule] |
| [PipelineSummary](../../../Sources/KabanProtocol/Pipeline.swift#L164) | projectId:ProjectID; versionHash:String?; gitPreset:GitPreset; maxWaitingHuman:Int; maxRunsPerTask:Int; stages:[StageSummary]; issues:[ValidationIssue]; hasUncommittedEdits:Bool; defaultReturnStage:StageID?; projectGitPolicy:EffectiveGitPolicy?; gitCommandCatalog:[String]=[] |
| [ValidationIssue](../../../Sources/KabanProtocol/Pipeline.swift#L213) | path:String; stageId:StageID?; code:String; message:String; severity:Severity; params:[String: String]=[:] |
| [FileBlobRef](../../../Sources/KabanProtocol/Commands.swift#L73) | path:String; blob:String |
| [AcceptedFile](../../../Sources/KabanProtocol/Commands.swift#L80) | path:String; blob:String; by:Actor; at:Date; commandId:CommandID? |
| [QuotaOptions](../../../Sources/KabanProtocol/Commands.swift#L95) | enabled:Bool; consent:Bool; pollInterval:Int; thresholdCm:Double; thresholdOm:Double |
| [McpServerRef](../../../Sources/KabanProtocol/Commands.swift#L107) | name:String; source:Source |
| [CommandEnvelope](../../../Sources/KabanProtocol/Commands.swift#L115) | protocolVersion:Int; commandId:CommandID; command:Command |
| [CommandReply](../../../Sources/KabanProtocol/Commands.swift#L124) | commandId:CommandID; seq:Seq?; result:CommandResult |
| [CommandError](../../../Sources/KabanProtocol/Commands.swift#L148) | code:String; message:String; params:[String: String]=[:] |
| [GitIdentity](../../../Sources/KabanProtocol/Commands.swift#L178) | name:String; email:String |
| [EnvironmentReport](../../../Sources/KabanProtocol/Commands.swift#L184) | cursorAgentPath:String?; version:String?; authOK:Bool; gitVersion:String?; sandboxOK:Bool; notificationsAuthorized:Bool |
| [TaskDetail](../../../Sources/KabanProtocol/Commands.swift#L198) | seq:Seq; task:TaskCard; feed:[FeedItem]; runs:[RunSummary]; humanRequests:[HumanRequest]; suspiciousFiles:[SuspiciousFile]; acceptedFiles:[AcceptedFile]; clonePath:String? |
| [FeedItem](../../../Sources/KabanProtocol/Commands.swift#L218) | id:String; at:Date; kind:String; text:String; runId:RunID? |
| [ModelInfo](../../../Sources/KabanProtocol/Models.swift#L4) | id:ModelID; name:String; pool:ModelPool; needsReview:Bool; forbidden:Bool; missingSince:Date? |
| [ModelPoolRule](../../../Sources/KabanProtocol/Models.swift#L17) | pattern:String; pool:ModelPool; source:Source |
| [ModelFlag](../../../Sources/KabanProtocol/Models.swift#L43) | modelId:ModelID; reason:Reason; requested:String; actual:String?; fallbackModel:String?; since:Date; lastProbeAt:Date? |
| [EventEnvelope](../../../Sources/KabanProtocol/Events.swift#L5) | seq:Seq; at:Date; projectId:ProjectID?; commandId:CommandID?; event:JournalEvent |
| [TaskTransition](../../../Sources/KabanProtocol/Events.swift#L52) | taskId:TaskID; fromStage:StageID; toStage:StageID; from:TaskState; to:TaskState; by:Actor; runId:RunID?; note:String? |
| [SettingsChange](../../../Sources/KabanProtocol/Events.swift#L67) | key:String; value:String |
| [HumanRequest](../../../Sources/KabanProtocol/Events.swift#L73) | requestId:HumanRequestID; taskId:TaskID; runId:RunID?; question:String |
| [HumanAnswer](../../../Sources/KabanProtocol/Events.swift#L83) | taskId:TaskID; requestId:HumanRequestID?; text:String |
| [GitDenied](../../../Sources/KabanProtocol/Events.swift#L90) | denialId:DenialID; taskId:TaskID; runId:RunID; argv:[String]; rule:String |
| [GitGrantCreated](../../../Sources/KabanProtocol/Events.swift#L96) | grantId:GrantID; denialId:DenialID; argv:[String]; by:Actor |
| [GitGrantDelivered](../../../Sources/KabanProtocol/Events.swift#L100) | grantId:GrantID; runId:RunID; via:GitGrantDeliveryVia |
| [GitGrantRef](../../../Sources/KabanProtocol/Events.swift#L104) | grantId:GrantID; runId:RunID |
| [GitGrantRevoked](../../../Sources/KabanProtocol/Events.swift#L108) | grantId:GrantID; by:Actor |
| [GitGrantExpired](../../../Sources/KabanProtocol/Events.swift#L112) | grantId:GrantID; reason:GitGrantExpiryReason |
| [GitPolicyUpdated](../../../Sources/KabanProtocol/Events.swift#L116) | projectId:ProjectID; scope:PolicyScope; pipelineVersion:String |
| [IncidentResolved](../../../Sources/KabanProtocol/Events.swift#L120) | incidentId:IncidentID; by:Actor; commandId:CommandID? |
| [SuspiciousFilesFound](../../../Sources/KabanProtocol/Events.swift#L124) | taskId:TaskID; runId:RunID?; stageId:StageID; files:[SuspiciousFile] |
| [SuspiciousFilesAccepted](../../../Sources/KabanProtocol/Events.swift#L128) | taskId:TaskID; files:[SuspiciousFile]; by:Actor; commandId:CommandID? |
| [RunnerCheck](../../../Sources/KabanProtocol/Events.swift#L261) | ok:Bool; reason:RunnerUnavailableReason?; version:String?; checkedAt:Date |
| [PipelineDraftValidation](../../../Sources/KabanProtocol/Events.swift#L267) | projectId:ProjectID; contentHash:String; issues:[ValidationIssue]; resolved:PipelineSummary? |
| [RunProgress](../../../Sources/KabanProtocol/Events.swift#L277) | runId:RunID; taskId:TaskID; message:String?; lastActivityAt:Date |

## Raw enums и single-value типы

Raw enums закрыты: unknown value → error, кроме GitRule.source wrapper (unknown → nil).
Пример каждого raw enum — одно значение в fixture под указанным именем.

| Тип | Wire значения |
|---|---|
| IncidentKind | refs_moved, tags_changed, config_changed, kaban_dir_changed, foreign_base |
| TaskStatus | queued, running, gating, retry_wait, waiting_human, paused, blocked, done, cancelled |
| WaitingHumanReason | question, review, retries_exhausted, bounce_limit, conflict_limit, run_limit, model_substituted, git_denials, incident, suspicious_files, invalid_result |
| QueuedReason | wip_full, quota_cm, quota_om, model_flag |
| RetryWaitReason | crash, stall_timeout, wall_timeout, no_final_call, gate_failed, rate_limit, runner_auth, daemon_restart, silent_exit, readonly_violation |
| BlockedReason | main_dirty |
| RunStatus | starting, running, succeeded, failed, killed |
| RunEndReason | crash, stall_timeout, wall_timeout, no_final_call, gate_failed, rate_limit, runner_auth, daemon_restart, silent_exit, model_substituted, readonly_violation, completed, returned, asked_human, paused_by_human, moved_by_human |
| StageKind | queue, agent, gate, human, merge, terminal |
| GitPreset | strict, standard, permissive |
| StageCommitter | daemon_only, agent_with_safety_commit |
| GitRuleSource | preset, project, stage |
| IncidentListState | open, all |
| GitGrantDeliveryVia | mcp_response, next_prompt |
| GitGrantExpiryReason | task_done, task_cancelled |
| Actor | human, agent, daemon, scheduler |
| ModelPool | cm, om |
| RunnerUnavailableReason | agent_missing, agent_not_runnable, agent_not_logged_in, runner_auth |
| ProjectUnavailableReason | project_missing, no_pipeline, pipeline_invalid, mcp_unexpected |
| ValidationIssue.Severity | error, warning |
| ProjectSummary.Availability | available, missing |
| SuspiciousFile.Rule | pattern, size |
| McpServerRef.Source | project, personal |
| ModelPoolRule.Source | builtin, user |
| ModelFlag.Reason | unavailable, substituted |
| SchedulerFlag.Level | mac, pool, project |

ProjectID, TaskID, RunID, StageID, ModelID, IncidentID, DenialID, GrantID, HumanRequestID
наследуют KabanID: String, пример одноимённый; пустой ID codec не запрещает.
CommandID = UUID string; Seq = Int64 number. Ключи примеров CommandID/Seq.

## Команды (46)

В каждой строке имя fixture `command.<имя>`. Имена полей совпадают с wire labels.
CommandEnvelope = protocolVersion/commandId/command; CommandReply = commandId/seq?/result.
`?` означает missing/null → nil; остальные аргументы mandatory. Decode defaults
у Command cases нет (даже `addProject.identity` — nil при отсутствии по optional type).
По комментарию CommandReply: `seq` — seq порождённого journal event; у чтений nil.
В main нет handler; возможные result payloads приведены ниже без назначения
конкретным командам как доказанного runtime контракта. Вся domain validation — daemon.

| Case | Аргументы |
|---|---|
| addProject | path:String; createTemplate:Bool; identity:GitIdentity? |
| setProjectIdentity | projectId:ProjectID; identity:GitIdentity |
| removeProject | projectId:ProjectID |
| relinkProject | projectId:ProjectID; path:String |
| listBranches | projectId:ProjectID |
| detectGates | projectId:ProjectID |
| setMascot | projectId:ProjectID; seed:String |
| setProjectWeight | projectId:ProjectID; weight:Int; maxRuns:Int? |
| updatePipeline | projectId:ProjectID; contentHash:String |
| validatePipeline | projectId:ProjectID; content:String |
| getTaskDetail | taskId:TaskID |
| createTask | projectId:ProjectID; title:String; body:String |
| editTask | taskId:TaskID; title:String?; body:String? |
| setPriority | taskId:TaskID; priority:Int |
| moveTask | taskId:TaskID; stage:StageID |
| pauseTask | taskId:TaskID |
| resumeTask | taskId:TaskID |
| cancelTask | taskId:TaskID; keepBranch:Bool |
| retryStage | taskId:TaskID; grantAttempts:Int? |
| setModelOverride | taskId:TaskID; stageId:StageID; model:ModelID? |
| answerHuman | taskId:TaskID; text:String; requestId:HumanRequestID? |
| approve | taskId:TaskID |
| requestChanges | taskId:TaskID; comments:String; target:StageID? |
| reject | taskId:TaskID; target:RejectTarget; keepBranch:Bool |
| acceptSuspiciousFiles | taskId:TaskID; files:[FileBlobRef] |
| allowGitOnce | denialId:DenialID |
| addDenialToPolicy | denialId:DenialID; scope:PolicyScope |
| revokeGitGrant | grantId:GrantID |
| pauseAll | — |
| resumeAll | — |
| pauseProject | projectId:ProjectID |
| resumeProject | projectId:ProjectID |
| resumeAfterRateLimit | — |
| setMaxConcurrentRuns | count:Int |
| checkEnvironment | — |
| recheck | scope:RecheckScope |
| listModels | — |
| refreshModelCatalog | — |
| setModelPoolRule | pattern:String; pool:ModelPool |
| removeModelPoolRule | pattern:String |
| clearModelFlag | modelId:ModelID |
| setQuotaOptions | options:QuotaOptions |
| listProjectMcpServers | projectId:ProjectID |
| setProjectMcpAllowlist | projectId:ProjectID; servers:[McpServerRef] |
| getRunHistory | taskId:TaskID |
| listIncidents | projectIds:[ProjectID]?; state:IncidentListState |

CommandResult: ok; pipelineVersion(hash:String); validationIssues(_0:[ValidationIssue]);
branches(_0:[String]); gates(_0:[String]); taskCreated(_0:TaskID); environment(_0:EnvironmentReport);
models(_0:[ModelInfo]); mcpServers(_0:[McpServerRef]); incidents(_0:[Incident]);
runs(_0:[RunSummary]); taskDetail(_0:TaskDetail); error(_0:CommandError).
Пример CommandResult показывает taskDetail. unknown case → decode error.
getSnapshot(projectIds?), subscribe(fromSeq,projectIds?), tailLog(runId,fromOffset) —
transport APIs A §5, не Command cases; request DTO пока не объявлены.

Требования к ответам из A §5 (handler ещё отсутствует):

| Команда | Описанный ответ / граница знания |
|---|---|
| updatePipeline | pipelineVersion(hash) либо validationIssues; errors также возможны |
| getTaskDetail | taskDetail(TaskDetail) |
| checkEnvironment | environment(EnvironmentReport) |
| listBranches / detectGates | branches / gates — соответствующие cases доступны, привязка выведена из имени и описания команды |
| createTask | taskCreated — case доступен, привязка выведена из имени; A не задаёт форму ответа |
| listModels / listProjectMcpServers / getRunHistory / listIncidents | models / mcpServers / runs / incidents — соответствующие DTO доступны; точная привязка выведена из описания чтений |
| validatePipeline | результат валидации требуем; синхронный validationIssues и/или ephemeral pipelineDraftValidated пока не определены |
| Остальные 35 команд | конкретный success case не определён; наличие ok не доказывает mapping handler |

Любая ошибка передаётся как `error(_0:CommandError)`. Форма, например:
`{"error":{"_0":{"code":"invalid_state","message":"synthetic","params":{}}}}`.
`seq` у read-команд nil по комментарию DTO; при нескольких journal events выбор seq
требует решения владельца. A §5 требует ожидать journal event с commandId;
это требование UI/daemon, а не автоматическое поведение Codable.

## События и нестандартные enums

| Тип | Shape / cases; обязательность |
|---|---|
| TaskState | status mandatory; reason optional для queued; mandatory retry_wait/waiting_human/blocked; остальные статусы reason игнорируют |
| SchedulerFlag | level+flag mandatory; rate_limited:until:Date,step:Int; runner_unavailable:reason; pool usage_exhausted:pool,resetsAt?; mac usage_exhausted:resetsAt?; project cases:projectId; unavailable:reason,detail? |
| PolicyScope | kind=project или stage+stageId:String; unknown kind error |
| RejectTarget | cancel:{} или stage:{stageId:String}; unknown case error |
| RecheckScope | runner:{} или project:{projectId:String}; unknown case error |
| AgentEvent | initialized(modelName?:String,sessionId?:String); message(role,text); toolCall(id,name,summary); toolResult(id,ok:Bool,summary); usage(inputTokens?:Int,outputTokens?:Int); error(code?:String,message); result(ok:Bool,durationMs?:Int) |

SchedulerFlag: wire поля `level` и `flag` обязательны во всех вариантах;
ниже все допустимые пары и остальные поля (decode defaults нет).

| level / flag | Поля и кодируемый reason |
|---|---|
| mac / paused | reason=manual при encode; decode reason не читает |
| mac / rate_limited | until:Date, step:Int mandatory |
| mac / usage_exhausted | resetsAt:Date?; reason=unknown при encode, decode его не читает |
| mac / runner_unavailable | reason:RunnerUnavailableReason mandatory |
| pool / usage_exhausted | pool:ModelPool mandatory; resetsAt:Date?; encode reason=pool.rawValue, decode его не читает |
| project / paused | projectId mandatory; reason=manual при encode, decode его не читает |
| project / intake_paused | projectId mandatory; reason=max_waiting_human при encode, decode его не читает |
| project / unavailable | projectId, reason:ProjectUnavailableReason mandatory; detail:String? |
| project / merge_blocked | projectId mandatory; reason=main_dirty при encode, decode его не читает |

TaskState/SchedulerFlag unknown discriminator и читаемый reason → error;
reason у простых статусов/флагов игнорируется даже при неизвестной строке. Journal/Ephemeral future type →
unknown(type), opaque data discarded; known type requires matching data (resyncRequired без data).
Все event payload fields приведены в DTO таблице; envelope seq/at mandatory,
projectId/commandId optional. Ephemeral без seq; replay/delivery гарантирует transport, не codec.

| JournalEvent tag; fixture JournalEvent.<tag> | data type |
|---|---|
| taskCreated | TaskCard |
| taskUpdated | TaskCard |
| taskTransitioned | TaskTransition |
| taskEdited | TaskCard |
| projectAdded | ProjectSummary |
| projectUpdated | ProjectSummary |
| projectRemoved | ProjectID |
| pipelineApplied | PipelineSummary |
| settingsChanged | SettingsChange |
| humanRequested | HumanRequest |
| humanAnswered | HumanAnswer |
| gitDenied | GitDenied |
| gitGrantCreated | GitGrantCreated |
| gitGrantDelivered | GitGrantDelivered |
| gitGrantConsumed | GitGrantRef |
| gitGrantRevoked | GitGrantRevoked |
| gitGrantExpired | GitGrantExpired |
| gitPolicyUpdated | GitPolicyUpdated |
| incidentOpened | Incident |
| incidentResolved | IncidentResolved |
| suspiciousFilesFound | SuspiciousFilesFound |
| suspiciousFilesAccepted | SuspiciousFilesAccepted |
| stageLoadChanged | StageLoad |
| unknown | wire type — неизвестная строка; Swift `.unknown(type:)`, data игнорируется |

| EphemeralEvent tag; fixture EphemeralEvent.<tag> | data type |
|---|---|
| schedulerFlagsChanged | [SchedulerFlag] |
| modelFlagsChanged | [ModelFlag] |
| quotaUpdated | QuotaState |
| modelCatalogChanged | [ModelInfo] |
| runnerChecked | RunnerCheck |
| pipelineDraftValidated | PipelineDraftValidation |
| runProgress | RunProgress |
| resyncRequired | — |
| unknown | wire type — неизвестная строка; Swift `.unknown(type:)`, data игнорируется |

## CommandError и params

| Код | params / смысл |
|---|---|
| unknown_command | schema params не задана; неизвестный Command throws, mapping делает listener |
| invalid_state | schema params не задана; запрещённое domain действие |
| not_found | schema params не задана; отсутствующий объект |
| protocol_mismatch | schema params не задана; negotiation listener |
| stale_suspicious_files | schema params не задана; path/blob set изменился |
| identity_required | missing=name/email/name,email; invalid те же списки; найденные корректные name/email; каждая часть disjoint, rejected value не возвращается |

code/message mandatory, params missing/null → [:]. Unknown code сохраняется как String;
message — fallback. fixture CommandError демонстрирует missing=email+name=Team2.
ValidationIssue.code тоже открыт; severity error/warning управляет blocking.
Fixture ValidationIssue содержит params.n; список ValidationCode отдельно AN4.

## Helpers и вопросы владельцу

KabanCoding.makeEncoder(pretty)/makeDecoder: camelCase, sorted JSON, protocolVersion=1.
HardInvariant.all: push,remote,config,tag,force,foreign_refs,kaban_dir, порядок канонический;
EffectiveGitPolicy.hardInvariants — открытые string IDs, неизвестные сохраняются.
GitRuleSource= preset/project/stage; source неизвестный в GitRule → nil.
StageCommitter strict→daemon_only; standard/permissive→agent_with_safety_commit —
resolver, не codec. ConditionalGitRule.returnReason открытая строка.
PipelineSummary.isValid проверяет только severity error; resolved defaults считает daemon.
TaskStatus.occupiesWIP: running/gating/retry_wait; in human — кроме queued/done/cancelled;
WaitingHumanReason.countsTowardMaxWaitingHuman исключает review;
RetryWaitReason.chargesAttempt исключает rate_limit/runner_auth/daemon_restart/silent_exit.
ModelPoolResolver.pool: user rules прежде builtin composer-*→cm, иначе om; wildcard только terminal *.
QuotaState.percentUsed/effectiveCycleStart/isStale; BillingCycle.startFallback/parseEpochMillis;
Calendar.utc Gregorian UTC. UnknownTag(type:String) — public error helper, не Codable.
ValidationCode — 37 публичных String-констант из Pipeline.swift (§4.1 спеки);
это не Codable enum, wire sample — `ValidationIssue.code`; инвентарь и params ведёт AN4.
Все helpers не имеют wire object/sample; публичные init/Codable/Hashable/Sendable методы
не добавляют полей. KabanID protocol наследует Codable, конкретные IDs перечислены выше.

Не хватает договорённости: durable artifacts/gitGrants/gitDenials в TaskDetail
([#14](https://github.com/imedfan/kaban/issues/14)); полный future-version recovery;
какие ephemeral current values восстанавливает Snapshot; incidentOpened id vs incidentId
в описании A; schema params для ошибок кроме identity_required; allowed glob syntax
model_pool_rule; ответ handler каждой команды и seq при нескольких journal событиях.
Ни один отсутствующий handler/default не выдуман. JSON samples гарантируют codec roundtrip, а не domain-проверки.

Проверка на macOS 2026-10-04: filtered test — 1/1; full suite —
Protocol 33, Kit 107, BoardCore 46, всего 186, failures/skips 0.
Команда: `KABAN_SCENARIOS=Scenarios/M1 swift test` с `--disable-sandbox`,
изолированными `--scratch-path`, `--cache-path`, `--config-path`, `--security-path`
и module cache в `/private/tmp`. Linux Swift 6 проверяется отдельно в CI;
локальный результат этого не подтверждает.
Уверенность высокая для wire-полей и decode defaults; средняя для описанного domain
смысла и ответа handler. Не выполнено: runtime XPC/replay и domain validation,
потому что реализация listener отсутствует в baseline. Существующие тесты,
fixtures, Sources, Package.swift, CI и Scenarios не изменены.
