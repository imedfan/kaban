# A1 — архитектура, спецификация и публичный протокол

Дата: 2026-10-04. Baseline main `1d647eaf9f937780b8a78dbd6bf5db94a5b98f64`.
Область: architecture v0.11.22 §3/§5/§8/§12, spec v0.8.24 и весь
публичный `Sources/KabanProtocol`. ValidationCode сверяется отдельно AN4.
Production-код, существующие тесты и документы не изменены.

Источники A = [architecture-v0.md v0.11.22](https://drive.google.com/file/d/1q-TwZPODCOF_pogtXJU5N8niNp1ePLEs/view);
S = [spec v0.8.24](https://drive.google.com/file/d/1z7MT3ezZ5V7d5BoIBWaMjnTg_iHMSFKQ/view);
D = [decisions-log](https://drive.google.com/file/d/1AGNwKUwZ_YcOzh0A3LAg2zUWx-_71wxx/view), MCP/git.
Использованы read-only выгрузки `/private/tmp/kaban-team2-context/`,
а не устаревшие копии репозитория. Ссылки A/S ниже содержат раздел и
номер строки этой выгрузки; версии фиксированы выше. Строки кода — baseline.

Вердикт: основные DTO стадий, identity, git-политики и hard invariants
соответствуют требуемому представлению. **Есть пробел TaskDetail**:
объявленные §5 `artifacts`, `gitGrants`, `gitDenials` отсутствуют в DTO.
Универсальные проверки domain-инвариантов и версии transport в Codable
не реализованы; они относятся к валидатору/демону, отсутствие проверки
само по себе не считается ошибкой протокола.

Метки: **OK** — представление соответствует; **GAP** — поля/типа нет;
**Q** — неоднозначность/открытый контракт; **BOUNDARY** — Codable допускает
значение, семантическую проверку обязан выполнить другой слой.
`?` — optional, отсутствующий/null ключ читается как nil. `=[]`/`=[:]`
в примечаниях — именно decode-дефолт, не только Swift init-дефолт.
Синтезированный Codable требует все неoptional stored поля независимо
от init-дефолтов и игнорирует неизвестные JSON-ключи.

## Приоритетные расхождения и границы

| Приоритет/статус | Доказательство | Влияние и решение для основной команды |
|---|---|---|
| P1 GAP [#14](https://github.com/imedfan/kaban/issues/14) | A §5 L274: TaskDetail перечисляет artifacts/gitGrants/gitDenials; код Commands.swift:198–215 их не содержит | После reconnect панель не получает долговечные артефакты и полные разрешения/отказы. Journal и `unusedGitGrants` не заменяют snapshot деталей. Добавление публичных полей — только владельцем протокола |
| P2 Q | A §5 L278: текущие ephemeral значения приходят в snapshot; A L273 и Entities.swift:175 описывают snapshot без catalog/runner/draft/progress | Уточнить, какие значения восстанавливаются отдельными запросами/новыми ephemeral событиями, а какие действительно snapshot. Это внутреннее расхождение A, не доказанная runtime ошибка |
| P2 Q | A §5 L287: incidentOpened `{incidentId,...}`; код Events.swift:42 несёт `Incident` с ключом `id` (Entities.swift:157) | Клиент, использующий DTO, согласован с демоном на DTO; внешний подписчик по буквальной схеме архитектуры ждёт другой ключ. Уточнить описательную запись или wire shape |
| P2 Q | A §3.2 L175: в human WIP все кроме queued; код TaskState.swift:16 исключает также done/cancelled | Таблица A L166–167 освобождает терминальные статусы; код разумно согласован с ней. Уточнить формулировку исключения; не считать runtime багом без допустимого терминального task в human |
| BOUNDARY | Coding.swift:5 + Snapshot decode Entities.swift:195–203; CommandEnvelope синтезированный | protocolVersion=999 декодируется; XPC обязан проверить до обработки. В пакете нет сервиса/handshake; нельзя утверждать, что `protocol_mismatch` автоматически отправляется |
| BOUNDARY | Pipeline.swift:135 допускает `hardInvariants=[]` при отсутствующем ключе | Совместимость со старым демоном; это не снятие защиты в резолвере. Текущий демон обязан отдавать все 7, UI не должен считать пустой список доказательством отсутствия ограничений |
| BOUNDARY | GitIdentity / CommandError.params — обычные strings/dictionary | Trim, newline/NUL до trim, missing/invalid partition, автор и отсутствие мутации проверяет handler, не Codable. Некорректный DTO успешно декодируется |

## Ключевые типы, каждый элемент

| Элемент | Статус; источник | Фактический контракт Codable / владельца |
|---|---|---|
| StageKind: queue, agent, gate, human, merge, terminal | OK A §3.1 L88–96; S §1.5 | Закрытый String enum; неизвестный kind throws; [Pipeline:3](../../../Sources/KabanProtocol/Pipeline.swift#L3) |
| StageDisplay.icon?, color?, order, collapsed, hidden | OK A §3.1 L109; S §1.5 | order/collapsed/hidden обязательны на wire; init defaults не decode defaults; [Pipeline:8](../../../Sources/KabanProtocol/Pipeline.swift#L8) |
| StageReturn.stage, limit | OK/BOUNDARY A §3.1 L149; S §1.3 L61–65 | Оба required; отрицательный limit / read-only target Codable не запрещает; [Pipeline:19](../../../Sources/KabanProtocol/Pipeline.swift#L19) |
| StageSummary.id, name, kind, display | OK A §3.1 | Все required; [Pipeline:26](../../../Sources/KabanProtocol/Pipeline.swift#L26) |
| StageSummary.wip?, model? | OK/BOUNDARY A §3.1 L151–153 | Отсутствуют/null → nil; `agent` без model декодируется, pipeline validator обязан остановить |
| StageSummary.readOnly, returnsTo | OK A §3.1/§8.4; S §1.3 | Required; отсутствие не подставляет init false/[]; цепочки и допустимые цели проверяет KabanKit |
| StageSummary.onSuccess?, maxAttempts? | OK/BOUNDARY A §3.1 | nil разрешён codec; граф и границы не проверяются |
| StageSummary.gates | OK A §3.1 | missing/null → []; gate с [] может быть DTO невалидного draft |
| StageSummary.onFail?, onConflict? | OK A §3.1 L149; S §1.3 L65 | resolved stage+limit от демона; nil совместим со старым демоном; UI не вычисляет fallback |
| StageSummary.gitPolicy? | OK A §8.4 L392 | nil старый/non-agent; код допускает и agent nil; resolve обязан дать актуальный policy |
| PipelineSummary.projectId, versionHash? | OK A §3.1 | hash nil если нет валидной версии; decode не проверяет consistency issues/hash; [Pipeline:164](../../../Sources/KabanProtocol/Pipeline.swift#L164) |
| PipelineSummary.gitPreset, maxWaitingHuman, maxRunsPerTask | OK A §3.1; S §4 | Required wire; init defaults standard/3/12 не применяются decoder |
| PipelineSummary.stages, issues, hasUncommittedEdits | OK A §3.1 L136–153 | Required; `isValid` смотрит только severity error, не наличие hash |
| PipelineSummary.defaultReturnStage? | OK A §3.1 L149; S §1.3 L65 | nil старый/no eligible target; клиент не выбирает первую стадию сам |
| PipelineSummary.projectGitPolicy?, gitCommandCatalog | OK A §8.4 L392 | policy optional; catalog missing/null → []; no local rule resolution |
| EffectiveGitPolicy.preset, allowed, committer, readOnly | OK A §8.4; S §1.5 | Required; closed preset/committer enums; [Pipeline:111](../../../Sources/KabanProtocol/Pipeline.swift#L111) |
| EffectiveGitPolicy.denied, hardInvariants, conditional | OK/BOUNDARY A §8.2/§8.4 | Каждый missing/null → []; sorted order/content/deny precedence не enforced codec |
| GitRule.rule, source? | OK A §8.4 L392 | rule required; source missing/null/unknown string → nil; malformed nonstring throws; [Pipeline:94](../../../Sources/KabanProtocol/Pipeline.swift#L94) |
| GitRuleSource.preset, project, stage | OK A §8.4; S UC-19 | Последний изменивший решение слой; direct enum decoder unknown throws, GitRule wrapper даёт nil |
| ConditionalGitRule.returnReason, allowed | OK/BOUNDARY A §8.4 | returnReason открытый string; allowed required; source=stage и исключение denied — resolver, не codec |
| StageCommitter.daemon_only, agent_with_safety_commit | OK A §6.3/§8.4; S §1.5 L112–114 | Raw wire значения совпадают; codec не связывает committer с preset |
| HardInvariant push/remote/config/tag/force/foreign_refs/kaban_dir | OK A §8.2 L368; S §1.5 | `HardInvariant.all` ровно этот порядок; открытые string IDs, неизвестные сохраняются; [Pipeline:141](../../../Sources/KabanProtocol/Pipeline.swift#L141) |
| ProjectSummary.identity? | OK A §8.2 L366; S UC-01 L199 | missing/null → nil; typed GitIdentity; текущий daemon обязан иметь identity у registered проекта; [Entities:3](../../../Sources/KabanProtocol/Entities.swift#L3) |
| GitIdentity.name, email | OK/BOUNDARY A §8.2; S UC-01 | Required strings; никакой email regex/trim/invalid-check на wire; [Commands:178](../../../Sources/KabanProtocol/Commands.swift#L178) |
| Command.addProject.identity? / setProjectIdentity.identity | OK A §5/§8.2; S UC-01 | addProject без identity декодируется nil; setProjectIdentity требует name/email; проверки и no mutation — handler |
| CommandError.code, message, params | OK A §8.2 L366; S UC-01 | params missing/null → [:]; strings unchanged; [Commands:145](../../../Sources/KabanProtocol/Commands.swift#L145) |
| identity_required params missing/invalid/name/email | OK schema / BOUNDARY semantics | Порядок name,email и disjoint partition описаны; codec допускает любые пары, это не доверенные найденные значения без handler validation |
| ValidationIssue.path, stageId?, code, message, severity, params | OK A §3.1 L145 | params missing/null → [:], code открытый string, severity закрытый error/warning; ValidationCode inventory в AN4 |
| PipelineDraftValidation.projectId, contentHash, issues, resolved? | OK A §3.1/§8.4 | required first3; optional resolved. Даже semantic-invalid draft должен иметь resolved, кроме YAML/root parse failure; handler обязан заполнить |

## Полный инвентарь остальных публичных типов и полей

Каждая строка перечисляет все stored поля / enum cases типа (кроме
ключевых типов выше, чьи поля уже разобраны). `Command` и events имеют
отдельные таблицы ниже. Для групповых transport enum формы прочитаны
реальные encode/decode switch, а не только комментарии.

| Тип; код | Поля / cases / helper | Статус; источник и замечание |
|---|---|---|
| AgentEvent; [AgentEvent.swift:4](../../../Sources/KabanProtocol/AgentEvent.swift#L4) | initialized(modelName: String?, sessionId: String?); message(role: String, text: String); toolCall(id: String, name: String, summary: String); toolResult(id: String, ok: Bool, summary: String); usage(inputTokens: Int?, outputTokens: Int?); error(code: String?, message: String); result(ok: Bool, durationMs: Int?) | OK A §5/§6.1: synthesized enum; future unknown case throws, это нормализованный лог а не JournalEvent |
| LogBatch; [AgentEvent.swift:15](../../../Sources/KabanProtocol/AgentEvent.swift#L15) | runId: RunID; fromOffset: Int64; nextOffset: Int64; events: [AgentEvent] | OK A §5 tailLog; offsets Int64, continuity проверяет transport |
| KabanCoding; [Coding.swift:4](../../../Sources/KabanProtocol/Coding.swift#L4) | protocolVersion=1; makeEncoder(pretty), makeDecoder() | OK/BOUNDARY A §5: protocolVersion=1; ISO8601 milliseconds encoder, decoder допускает без fractions |
| UnknownTag; [Coding.swift:50](../../../Sources/KabanProtocol/Coding.swift#L50) | type: String | OK A §5 compatibility helper; public error содержит type, event decoders не бросают его |
| FileBlobRef; [Commands.swift:73](../../../Sources/KabanProtocol/Commands.swift#L73) | path: String; blob: String | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| AcceptedFile; [Commands.swift:80](../../../Sources/KabanProtocol/Commands.swift#L80) | path: String; blob: String; by: Actor; at: Date; commandId: CommandID? | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| RejectTarget; [Commands.swift:91](../../../Sources/KabanProtocol/Commands.swift#L91) | cancel, stage(stageId: StageID) | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| RecheckScope; [Commands.swift:92](../../../Sources/KabanProtocol/Commands.swift#L92) | runner, project(projectId: ProjectID) | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| IncidentListState; [Commands.swift:93](../../../Sources/KabanProtocol/Commands.swift#L93) | open, all | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| QuotaOptions; [Commands.swift:95](../../../Sources/KabanProtocol/Commands.swift#L95) | enabled: Bool; consent: Bool; pollInterval: Int; thresholdCm: Double; thresholdOm: Double | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| McpServerRef; [Commands.swift:107](../../../Sources/KabanProtocol/Commands.swift#L107) | name: String; source: Source; Source=project / personal | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| CommandEnvelope; [Commands.swift:115](../../../Sources/KabanProtocol/Commands.swift#L115) | protocolVersion: Int; commandId: CommandID; command: Command | OK/BOUNDARY A §5: UUID/версия required, version mismatch проверяет transport |
| CommandReply; [Commands.swift:124](../../../Sources/KabanProtocol/Commands.swift#L124) | commandId: CommandID; seq: Seq?; result: CommandResult | OK A §5; seq optional для чтений, correlation проверяет handler/client |
| CommandResult; [Commands.swift:132](../../../Sources/KabanProtocol/Commands.swift#L132) | ok; pipelineVersion(hash: String); validationIssues([ValidationIssue]); branches([String]); gates([String]); taskCreated(TaskID); environment(EnvironmentReport); models([ModelInfo]); mcpServers([McpServerRef]); incidents([Incident]); runs([RunSummary]); taskDetail(TaskDetail); error(CommandError) | OK A §5: synthesized associated-value enum; unknown case throws |
| EnvironmentReport; [Commands.swift:184](../../../Sources/KabanProtocol/Commands.swift#L184) | cursorAgentPath: String?; version: String?; authOK: Bool; gitVersion: String?; sandboxOK: Bool; notificationsAuthorized: Bool | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| TaskDetail; [Commands.swift:198](../../../Sources/KabanProtocol/Commands.swift#L198) | seq: Seq; task: TaskCard; feed: [FeedItem]; runs: [RunSummary]; humanRequests: [HumanRequest]; suspiciousFiles: [SuspiciousFile]; acceptedFiles: [AcceptedFile]; clonePath: String? | GAP A §5/§12, S F8/UC-07: artifacts/gitGrants/gitDenials отсутствуют |
| FeedItem; [Commands.swift:218](../../../Sources/KabanProtocol/Commands.swift#L218) | id: String; at: Date; kind: String (открытый kind); text: String; runId: RunID? | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| ProjectSummary; [Entities.swift:3](../../../Sources/KabanProtocol/Entities.swift#L3) | id: ProjectID; name: String; path: String; baseBranch: String; availability: Availability; weight: Int; maxRuns: Int?; mascotSeed: String; openIncidentCount: Int; identity: GitIdentity?; Availability=available / missing | OK A §5/§8.2; identity nil и openIncidentCount=0 при missing/null |
| TaskCard; [Entities.swift:39](../../../Sources/KabanProtocol/Entities.swift#L39) | id: TaskID; projectId: ProjectID; title: String; stageId: StageID; state: TaskState; priority: Int; branch: String?; attempt: Int; maxAttempts: Int?; runsSinceHuman: Int; bounceByReason: [String: Int]; overlapsWith: [TaskID]; unusedGitGrants: Int; model: ModelID?; retryAt: Date?; suspiciousFiles: [SuspiciousFile]; hasAcceptanceCriteria: Bool; updatedAt: Date | OK A §3.2/§5; hasAcceptanceCriteria=false при missing/null; suspiciousFiles required |
| RunSummary; [Entities.swift:98](../../../Sources/KabanProtocol/Entities.swift#L98) | id: RunID; taskId: TaskID; stageId: StageID; number: Int; status: RunStatus; endReason: RunEndReason?; requestedModel: ModelID; actualModelName: String?; countsTowardLimits: Bool; startedAt: Date; endedAt: Date?; exitCode: Int32?; logPath: String?; wipRef: String? | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| SuspiciousFile; [Entities.swift:125](../../../Sources/KabanProtocol/Entities.swift#L125) | path: String; rule: Rule; pattern: String?; sizeBytes: Int64; isText: Bool; blob: String; Rule=pattern / size | OK A §8.2; isText missing/null → false, прочие nonoptional required |
| IncidentKind; [Entities.swift:148](../../../Sources/KabanProtocol/Entities.swift#L148) | refsMoved = "refs_moved"; tagsChanged = "tags_changed"; configChanged = "config_changed"; kabanDirChanged = "kaban_dir_changed"; foreignBase = "foreign_base" | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| Incident; [Entities.swift:156](../../../Sources/KabanProtocol/Entities.swift#L156) | id: IncidentID; projectId: ProjectID; taskId: TaskID; runId: RunID?; kind: IncidentKind; rolledBack: [String]; openedAt: Date; resolvedAt: Date? | Q A §5/§8.2: id vs incidentId в описательной схеме |
| Snapshot; [Entities.swift:172](../../../Sources/KabanProtocol/Entities.swift#L172) | protocolVersion: Int; seq: Seq; projects: [ProjectSummary]; pipelines: [PipelineSummary]; tasks: [TaskCard]; schedulerFlags: [SchedulerFlag]; modelFlags: [ModelFlag]; quota: QuotaState?; openIncidentCount: Int; stageLoad: [StageLoad] | OK/Q A §5; stageLoad missing/null → []; protocolVersion декодируется без проверки |
| StageLoad; [Entities.swift:208](../../../Sources/KabanProtocol/Entities.swift#L208) | projectId: ProjectID; stageId: StageID; wipUsed: Int; wipLimit: Int? | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| EventEnvelope; [Events.swift:5](../../../Sources/KabanProtocol/Events.swift#L5) | seq: Seq; at: Date; projectId: ProjectID?; commandId: CommandID?; event: JournalEvent | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantDeliveryVia; [Events.swift:18](../../../Sources/KabanProtocol/Events.swift#L18) | mcpResponse = "mcp_response", nextPrompt = "next_prompt" | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantExpiryReason; [Events.swift:19](../../../Sources/KabanProtocol/Events.swift#L19) | taskDone = "task_done", taskCancelled = "task_cancelled" | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| Actor; [Events.swift:20](../../../Sources/KabanProtocol/Events.swift#L20) | human, agent, daemon, scheduler | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| TaskTransition; [Events.swift:52](../../../Sources/KabanProtocol/Events.swift#L52) | taskId: TaskID; fromStage: StageID; toStage: StageID; from: TaskState; to: TaskState; by: Actor; runId: RunID?; note: String? | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| SettingsChange; [Events.swift:67](../../../Sources/KabanProtocol/Events.swift#L67) | key: String; value: String | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| HumanRequest; [Events.swift:73](../../../Sources/KabanProtocol/Events.swift#L73) | requestId: HumanRequestID; taskId: TaskID; runId: RunID?; question: String | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| HumanAnswer; [Events.swift:83](../../../Sources/KabanProtocol/Events.swift#L83) | taskId: TaskID; requestId: HumanRequestID?; text: String | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitDenied; [Events.swift:90](../../../Sources/KabanProtocol/Events.swift#L90) | denialId: DenialID; taskId: TaskID; runId: RunID; argv: [String]; rule: String | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantCreated; [Events.swift:96](../../../Sources/KabanProtocol/Events.swift#L96) | grantId: GrantID; denialId: DenialID; argv: [String]; by: Actor | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantDelivered; [Events.swift:100](../../../Sources/KabanProtocol/Events.swift#L100) | grantId: GrantID; runId: RunID; via: GitGrantDeliveryVia | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantRef; [Events.swift:104](../../../Sources/KabanProtocol/Events.swift#L104) | grantId: GrantID; runId: RunID | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantRevoked; [Events.swift:108](../../../Sources/KabanProtocol/Events.swift#L108) | grantId: GrantID; by: Actor | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitGrantExpired; [Events.swift:112](../../../Sources/KabanProtocol/Events.swift#L112) | grantId: GrantID; reason: GitGrantExpiryReason | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| GitPolicyUpdated; [Events.swift:116](../../../Sources/KabanProtocol/Events.swift#L116) | projectId: ProjectID; scope: PolicyScope; pipelineVersion: String | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| IncidentResolved; [Events.swift:120](../../../Sources/KabanProtocol/Events.swift#L120) | incidentId: IncidentID; by: Actor; commandId: CommandID? | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| SuspiciousFilesFound; [Events.swift:124](../../../Sources/KabanProtocol/Events.swift#L124) | taskId: TaskID; runId: RunID?; stageId: StageID; files: [SuspiciousFile] | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| SuspiciousFilesAccepted; [Events.swift:128](../../../Sources/KabanProtocol/Events.swift#L128) | taskId: TaskID; files: [SuspiciousFile]; by: Actor; commandId: CommandID? | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| PolicyScope; [Events.swift:134](../../../Sources/KabanProtocol/Events.swift#L134) | project; stage(StageID) | OK A §5; custom `{kind:project}` / `{kind:stage,stageId}`; unknown kind throws |
| RunnerCheck; [Events.swift:261](../../../Sources/KabanProtocol/Events.swift#L261) | ok: Bool; reason: RunnerUnavailableReason?; version: String?; checkedAt: Date | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| RunProgress; [Events.swift:277](../../../Sources/KabanProtocol/Events.swift#L277) | runId: RunID; taskId: TaskID; message: String?; lastActivityAt: Date | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| KabanID; [Identifiers.swift:4](../../../Sources/KabanProtocol/Identifiers.swift#L4) | rawValue:String; init(rawValue:), init(stringLiteral:), init(from:), encode(to:), description | OK A §4/§5: single string; пустые/нестандартные id не запрещены codec |
| ProjectID; [Identifiers.swift:15](../../../Sources/KabanProtocol/Identifiers.swift#L15) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| TaskID; [Identifiers.swift:16](../../../Sources/KabanProtocol/Identifiers.swift#L16) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| RunID; [Identifiers.swift:17](../../../Sources/KabanProtocol/Identifiers.swift#L17) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| StageID; [Identifiers.swift:18](../../../Sources/KabanProtocol/Identifiers.swift#L18) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| ModelID; [Identifiers.swift:19](../../../Sources/KabanProtocol/Identifiers.swift#L19) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| IncidentID; [Identifiers.swift:20](../../../Sources/KabanProtocol/Identifiers.swift#L20) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| DenialID; [Identifiers.swift:21](../../../Sources/KabanProtocol/Identifiers.swift#L21) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| GrantID; [Identifiers.swift:22](../../../Sources/KabanProtocol/Identifiers.swift#L22) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| HumanRequestID; [Identifiers.swift:23](../../../Sources/KabanProtocol/Identifiers.swift#L23) | rawValue: String | OK A §5; KabanID custom single-value string, не JSON object |
| CommandID; [Identifiers.swift:26](../../../Sources/KabanProtocol/Identifiers.swift#L26) | UUID | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| Seq; [Identifiers.swift:29](../../../Sources/KabanProtocol/Identifiers.swift#L29) | Int64 | OK A §5; синтезированный Codable; nonoptional required, unknown enum throws |
| ModelInfo; [Models.swift:4](../../../Sources/KabanProtocol/Models.swift#L4) | id: ModelID; name: String; pool: ModelPool; needsReview: Bool; forbidden: Bool; missingSince: Date? | OK A §4/§7; синтезированный Codable; nonoptional required, unknown enum throws |
| ModelPoolRule; [Models.swift:17](../../../Sources/KabanProtocol/Models.swift#L17) | pattern: String; pool: ModelPool; source: Source; Source=builtin / user; builtin composer-* → cm | OK A §4/§7; синтезированный Codable; nonoptional required, unknown enum throws |
| ModelPoolResolver; [Models.swift:28](../../../Sources/KabanProtocol/Models.swift#L28) | pool(for:rules:); user → builtin → om | OK A §4/§7; user раньше builtin, fallback om; glob только terminal *, multi-* contract не задан |
| ModelFlag; [Models.swift:43](../../../Sources/KabanProtocol/Models.swift#L43) | modelId: ModelID; reason: Reason; requested: String; actual: String?; fallbackModel: String?; since: Date; lastProbeAt: Date?; Reason=unavailable / substituted | OK A §4/§7; синтезированный Codable; nonoptional required, unknown enum throws |
| QuotaState; [Quota.swift:4](../../../Sources/KabanProtocol/Quota.swift#L4) | cm: Double?; om: Double?; billingCycleStart: Date?; billingCycleEnd: Date?; fetchedAt: Date | OK A §7: nullable проценты = no data; effectiveCycleStart/isStale helpers |
| BillingCycle; [Quota.swift:28](../../../Sources/KabanProtocol/Quota.swift#L28) | startFallback(end:calendar:), parseEpochMillis(raw) | OK A §7: month fallback и milliseconds parser; finite/bounds не проверены codec |
| ModelPool; [SchedulerFlags.swift:4](../../../Sources/KabanProtocol/SchedulerFlags.swift#L4) | cm, om | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| SchedulerFlag; [SchedulerFlags.swift:7](../../../Sources/KabanProtocol/SchedulerFlags.swift#L7) | macPaused; rateLimited(cooldownUntil,step); usageExhaustedUnknown(resetsAt?); runnerUnavailable(reason); poolUsageExhausted(pool,resetsAt?); projectPaused(id); intakePaused(id); projectUnavailable(id,reason,detail?); mergeBlocked(id); level(mac/pool/project) | OK A §3.2; flat level/flag/reason; unknown level/flag/reason throws |
| RunnerUnavailableReason; [SchedulerFlags.swift:34](../../../Sources/KabanProtocol/SchedulerFlags.swift#L34) | agentMissing = "agent_missing"; agentNotRunnable = "agent_not_runnable"; agentNotLoggedIn = "agent_not_logged_in"; runnerAuth = "runner_auth" | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| ProjectUnavailableReason; [SchedulerFlags.swift:41](../../../Sources/KabanProtocol/SchedulerFlags.swift#L41) | projectMissing = "project_missing"; noPipeline = "no_pipeline"; pipelineInvalid = "pipeline_invalid"; mcpUnexpected = "mcp_unexpected" | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| TaskStatus; [TaskState.swift:4](../../../Sources/KabanProtocol/TaskState.swift#L4) | queued, running, gating, retry_wait, waiting_human, paused, blocked, done, cancelled; occupiesWIP; occupiesWIP(in:) | OK/Q A §3.2; occupiesWIP human исключает done/cancelled, см. выше |
| WaitingHumanReason; [TaskState.swift:24](../../../Sources/KabanProtocol/TaskState.swift#L24) | question, review, retries_exhausted, bounce_limit, conflict_limit, run_limit, model_substituted, git_denials, incident, suspicious_files, invalid_result; countsTowardMaxWaitingHuman:Bool | OK A §3.2; countsTowardMaxWaitingHuman = reason != review |
| QueuedReason; [TaskState.swift:41](../../../Sources/KabanProtocol/TaskState.swift#L41) | wipFull = "wip_full"; quotaCm = "quota_cm"; quotaOm = "quota_om"; modelFlag = "model_flag" | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| RetryWaitReason; [TaskState.swift:48](../../../Sources/KabanProtocol/TaskState.swift#L48) | crash, stall_timeout, wall_timeout, no_final_call, gate_failed, rate_limit, runner_auth, daemon_restart, silent_exit, readonly_violation; chargesAttempt:Bool | OK A §3.2; chargesAttempt false только rate_limit/runner_auth/daemon_restart/silent_exit |
| BlockedReason; [TaskState.swift:70](../../../Sources/KabanProtocol/TaskState.swift#L70) | mainDirty = "main_dirty" | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| TaskState; [TaskState.swift:75](../../../Sources/KabanProtocol/TaskState.swift#L75) | queued(QueuedReason?), running, gating, retryWait(RetryWaitReason), waitingHuman(WaitingHumanReason), paused, blocked(BlockedReason), done, cancelled; status, reasonRawValue, countsTowardMaxWaitingHuman | OK A §3.2; status/reason flat; unknown enum/reason throws; причины обязательны только для retry_wait/waiting_human/blocked |
| RunStatus; [TaskState.swift:144](../../../Sources/KabanProtocol/TaskState.swift#L144) | starting, running, succeeded, failed, killed | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |
| RunEndReason; [TaskState.swift:146](../../../Sources/KabanProtocol/TaskState.swift#L146) | crash; stallTimeout = "stall_timeout"; wallTimeout = "wall_timeout"; noFinalCall = "no_final_call"; gateFailed = "gate_failed"; rateLimit = "rate_limit"; runnerAuth = "runner_auth"; daemonRestart = "daemon_restart"; silentExit = "silent_exit"; modelSubstituted = "model_substituted"; readonlyViolation = "readonly_violation"; completed, returned; askedHuman = "asked_human"; pausedByHuman = "paused_by_human"; movedByHuman = "moved_by_human" | OK A §3.2/§4/§5; синтезированный Codable; nonoptional required, unknown enum throws |

`Calendar.utc` ([Quota.swift:43](../../../Sources/KabanProtocol/Quota.swift#L43)) —
public helper Gregorian/UTC для BillingCycle, не wire-поле. `GitPreset`
strict/standard/permissive закрытый enum ([Pipeline.swift:5](../../../Sources/KabanProtocol/Pipeline.swift#L5)), A §8.4/S §1.5.

## Каждая XPC-команда и ответ

Все 46 cases `Command` совпадают с перечнем A §5 L293–303. Ассоциированные
поля ниже — точные типизированные аргументы wire; столбец ответов
сопоставляет существующие CommandResult с назначением команд, handler
в main отсутствует и фактические ответы не проверены; `?` не означает default
для других required полей. Код: [Commands.swift:5](../../../Sources/KabanProtocol/Commands.swift#L5).
Для каждой строки **OK schema / BOUNDARY behavior**: codec не проверяет
существование IDs, статус задачи, permissions, contentHash или размеры.

| Command; строка | Поля; ответ | Источник/граница |
|---|---|---|
| addProject; 9 | path:String, createTemplate:Bool, identity:GitIdentity?; ok/error | A §5/§8.2; S UC-01; identity_required до создания |
| setProjectIdentity; 12 | projectId, identity:GitIdentity; ok/error | A §8.2; S UC-01; новые коммиты, no mutation при отказе |
| removeProject; 13 | projectId; ok/error | A §5; detach project по handler |
| relinkProject; 14 | projectId, path:String; ok/error | A §5; проверка папки |
| listBranches; 15 | projectId; branches([String]) | A §5 |
| detectGates; 16 | projectId; gates([String]) | A §5; S UC-01 |
| setMascot; 17 | projectId, seed:String; ok/error | A §2/§5; S F22 |
| setProjectWeight; 18 | projectId, weight:Int, maxRuns:Int?; ok/error | A §3.4/§5; numeric validation handler |
| updatePipeline; 20 | projectId, contentHash:String; pipelineVersion(hash)/validationIssues | A §3.1/§5; атомарно только .kaban, stale hash поведение уточнить |
| validatePipeline; 21 | projectId, content:String; validationIssues | A §3.1/§5; draft resolved через ephemeral |
| getTaskDetail; 23 | taskId; taskDetail(TaskDetail) | A §5; GAP полей выше |
| createTask; 25 | projectId, title:String, body:String; taskCreated(TaskID) | A §5; S UC-01 |
| editTask; 26 | taskId, title:String?, body:String?; ok/error | A §5; только queued/waiting_human/paused |
| setPriority; 27 | taskId, priority:Int; ok/error | A §5 |
| moveTask; 28 | taskId, stage:StageID; ok/error | A §3.3/§5; S §1.3; read-only цель допустима; suspicious acceptance — handler |
| pauseTask; 29 | taskId; ok/error | A §3.3/§5 |
| resumeTask; 30 | taskId; ok/error | A §3.3/§5 |
| cancelTask; 31 | taskId, keepBranch:Bool; ok/error | A §5; keepBranch required в JSON, default false только API description |
| retryStage; 32 | taskId, grantAttempts:Int?; ok/error | A §3.3/§5; новый run, предел дополнительных попыток handler |
| setModelOverride; 33 | taskId, stageId, model:ModelID?; ok/error | A §5; nil снимает override; no Auto policy handler |
| answerHuman; 35 | taskId, text:String, requestId:HumanRequestID?; ok/error | A §3.3/§5; только waiting_human на agent; invalid_state иначе |
| approve; 36 | taskId; ok/error | A §3.3/§5; только human review, не принимает suspicious_files |
| requestChanges; 37 | taskId, comments:String, target:StageID?; ok/error | A §3.1/§3.3/§5; nil → resolved default; writable agent-only |
| reject; 38 | taskId, target:RejectTarget, keepBranch:Bool; ok/error | A §3.1/§5; cancel либо writable-agent target |
| acceptSuspiciousFiles; 41 | taskId, files:[FileBlobRef]; ok/error | A §8.2; S UC-25; exact path+blob set, stale_suspicious_files |
| allowGitOnce; 43 | denialId; ok/error | A §8.3; hard invariant не снимается |
| addDenialToPolicy; 44 | denialId, scope:PolicyScope; ok/error | A §8.3; те же validation/commit правила pipeline |
| revokeGitGrant; 45 | grantId; ok/error | A §5/§8.3 |
| pauseAll; 47 | без полей; ok | A §3.2/§5; текущие runs доигрывают |
| resumeAll; 48 | без полей; ok | A §3.2/§5 |
| pauseProject; 49 | projectId; ok/error | A §3.2/§5 |
| resumeProject; 50 | projectId; ok/error | A §3.2/§5 |
| resumeAfterRateLimit; 51 | без полей; ok | A §3.2/§5 |
| setMaxConcurrentRuns; 52 | count:Int; ok/error | A §3.4/§5; границы handler |
| checkEnvironment; 54 | без полей; environment(EnvironmentReport) | A §5 |
| recheck; 55 | scope:RecheckScope; ok/error | A §3.2/§5 |
| listModels; 57 | без полей; models([ModelInfo]) | A §5/§7; forbidden фильтрует daemon |
| refreshModelCatalog; 58 | без полей; ok | A §5/§7 |
| setModelPoolRule; 59 | pattern:String, pool:ModelPool; ok/error | A §4/§5; glob syntax пределы не определены |
| removeModelPoolRule; 60 | pattern:String; ok/error | A §5 |
| clearModelFlag; 61 | modelId; ok/error | A §3.2/§5 |
| setQuotaOptions; 62 | options:QuotaOptions; ok/error | A §5/§7; consent/ranges handler |
| listProjectMcpServers; 64 | projectId; mcpServers([McpServerRef]) | A §5/§9; discovery refs, не исходный конфиг/секреты |
| setProjectMcpAllowlist; 65 | projectId, servers:[McpServerRef]; ok/error | A §5/§9; source/name имеют значение; board всегда |
| getRunHistory; 67 | taskId; runs([RunSummary]) | A §5 |
| listIncidents; 69 | projectIds:[ProjectID]?, state:IncidentListState; incidents([Incident]) | A §5; nil = все проекты |

`getSnapshot`, `subscribe`, `tailLog` — transport APIs A §5, **не** cases
Command. Snapshot/EventEnvelope/LogBatch дают payload, но их запросы и
подписка в пакете не объявлены. Это отдельная будущая XPC реализация,
не следует отправлять выдуманный `Command.getSnapshot`.

Ошибки [Commands.swift:167](../../../Sources/KabanProtocol/Commands.swift#L167):
`unknown_command`, `invalid_state`, `not_found`, `protocol_mismatch`,
`stale_suspicious_files`, `identity_required`. Набор code открыт (String),
message — fallback, params=[:] для legacy. Неизвестный Command при decode
бросает DecodingError; mapping в unknown_command делает listener.
Ни one-command transaction, ни корреляция reply seq/event commandId не
обеспечиваются Codable; необходимы integration checks демона.

## Каждый journal и ephemeral тег

Код `Events.swift:22–49`, switch decode `:185–215`, encode `:218–244`.
Все known journal tags требуют `data`; unknown tag сохраняет только type,
его payload не сохраняется. Envelope seq/at required, projectId/commandId
optional. `unknown` не domain event и не должен применяться к проекции.

| Тег | Payload | Статус; источник |
|---|---|---|
| taskCreated, taskUpdated, taskEdited | TaskCard | OK A §5 L280; карточка целиком |
| taskTransitioned | TaskTransition | OK A §5; from/to/stage/by/runId?/note? |
| projectAdded, projectUpdated | ProjectSummary | OK A §5 |
| projectRemoved | ProjectID single string | OK A §5; название аргумента не JSON object |
| pipelineApplied | PipelineSummary | OK A §5 |
| settingsChanged | SettingsChange | OK A §5; key/value strings |
| humanRequested | HumanRequest | OK A §5 |
| humanAnswered | HumanAnswer | OK A §5 |
| gitDenied | GitDenied | OK A §5 L283 |
| gitGrantCreated | GitGrantCreated | OK A §5 L283 |
| gitGrantDelivered | GitGrantDelivered | OK A §5 L283; via mcp_response/next_prompt |
| gitGrantConsumed | GitGrantRef | OK A §5 L283 |
| gitGrantRevoked | GitGrantRevoked | OK A §5 L283 |
| gitGrantExpired | GitGrantExpired | OK A §5 L283; reason task_done/task_cancelled |
| gitPolicyUpdated | GitPolicyUpdated | OK A §5/§8.4; scope project либо stage |
| incidentOpened | Incident | Q A §5 L287: id vs incidentId |
| incidentResolved | IncidentResolved | OK A §5 L287 |
| suspiciousFilesFound | SuspiciousFilesFound | OK A §5 L285/§8.2 |
| suspiciousFilesAccepted | SuspiciousFilesAccepted | OK A §5 L285/§8.2 |
| stageLoadChanged | StageLoad | OK A §3.2 L175; same transaction с taskUpdated обязан daemon |
| unknown(type) | payload discarded | OK A §5: forward skip; resnapshot решает client |

`EphemeralEvent` — типизированный enum. Ephemeral encode/decode: `Events.swift:283–326`, тот же `{type,data}`.
Без seq. Known payload schema (таблица inventory) required; unknown
payload discarded. Ничего не гарантирует доставки/replay автоматически.

| Тег | Payload | Статус; источник |
|---|---|---|
| schedulerFlagsChanged | [SchedulerFlag] | OK A §5 L278; в Snapshot.schedulerFlags |
| modelFlagsChanged | [ModelFlag] | OK A §5 L278; в Snapshot.modelFlags |
| quotaUpdated | QuotaState | OK A §5 L278; в Snapshot.quota |
| modelCatalogChanged | [ModelInfo] | OK/Q A §5 L278; snapshot omission вопрос выше |
| runnerChecked | RunnerCheck | OK/Q A §5 L278; snapshot omission |
| pipelineDraftValidated | PipelineDraftValidation | OK/Q A §3.1/§5; snapshot omission |
| runProgress | RunProgress | OK/Q A §5 L278; snapshot omission |
| resyncRequired | без data | OK A §5 L275; взять свежий снимок |
| unknown(type) | payload discarded | OK A §5 forward skip |

`AgentEvent` — иной synthesized enum: initialized(modelName?,sessionId?),
message(role,text), toolCall(id,name,summary), toolResult(id,ok,summary),
usage(inputTokens?,outputTokens?), error(code?,message), result(ok,durationMs?).
Этот слой нормализует CLI для tailLog, не сохраняет исходный stream-json;
unknown enum case не переживает decode. Future reason/status тоже throws,
в отличие от будущего journal type: границу совместимости описывает A2.

## Воспроизведение и проверка

Изолированная программа `/private/tmp/kaban-a1-probe/main.swift` собрана
`swiftc -module-cache-path /private/tmp/kaban-a1-probe/cache
Sources/KabanProtocol/*.swift /private/tmp/kaban-a1-probe/main.swift -o
/private/tmp/kaban-a1-probe/probe`. Production sources не менялись.

Минимальный воспроизводитель основного пробела:

```swift
let e = KabanCoding.makeEncoder(), d = KabanCoding.makeDecoder()
let task = TaskCard(id: "t", projectId: "p", title: "synthetic", stageId: "human",
                    state: .waitingHuman(.review), updatedAt: Date(timeIntervalSince1970: 0))
let detail = TaskDetail(seq: 1, task: task, feed: [], runs: [])
var wire = try JSONSerialization.jsonObject(with: e.encode(detail)) as! [String: Any]
for key in ["artifacts", "gitGrants", "gitDenials"] { wire[key] = ["sentinel": "synthetic"] }
let decoded = try d.decode(TaskDetail.self, from: JSONSerialization.data(withJSONObject: wire))
let back = try JSONSerialization.jsonObject(with: e.encode(decoded)) as! [String: Any]
print(["artifacts", "gitGrants", "gitDenials"].filter { back[$0] == nil })
// ["artifacts", "gitGrants", "gitDenials"]
```

Sentinel deliberately не утверждает будущую схему: отсутствующие ключи
codec игнорирует при любом содержимом. A §5 даёт только имена этих полей,
не точные типы. Нужны решения владельца: Artifact summary, durable grant
summary (remaining uses, delivery/revocation/expiry, scope run/stage/task),
retained denial details. Existing event GitGrantCreated/GitDenied не
доказывают достаточность для долговечного snapshot после truncation.

Дополнительные фактические результаты этой программы: HardInvariant.all
совпадает с семью ID; отсутствующие policy hardInvariants читаются [];
Snapshot с protocolVersion 999 декодируется; CommandError без params → [:];
human+done не занимает WIP. Это boundary probes, не новые production bugs.
Прочитаны custom Codable и existing Compat/RoundTrip/Fixture tests;
проверены ссылки на исходники, полный inventory, `git diff --check`.

Открытые вопросы: schema отсутствующих деталей; транспортное recovery
эфемерных данных; incidentOpened id; WIP human terminal исключение;
version negotiation / unsupported error mapping; кто валидирует
identity_required params перед отображением. Согласованные решения
основной команды не менялись. Уверенность: высокая по wire DTO и GAP,
средняя по будущему transport/domain поведению — его кода в main нет.
