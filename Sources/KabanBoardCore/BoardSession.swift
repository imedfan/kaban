import Foundation
import Observation
import KabanProtocol

/// One application session. Views select data; they never own the update stream.
@MainActor @Observable public final class BoardSession {
    private let client: any KabanClient
    public let boardSet: BoardSetStore
    public private(set) var journal: ClientCommandJournal?
    public private(set) var drafts: TaskDraftStore?
    public private(set) var capabilities: DaemonCapabilities?
    public var projection: BoardProjection?
    public var connectionState: DaemonConnectionState = .connecting
    public private(set) var ephemeralCursor: EphemeralCursor?
    public private(set) var receivedEphemeralCursor: EphemeralCursor?
    public var selectedProjectID: ProjectID?
    public var selectedID: TaskID?
    public var detail: TaskDetail?
    public private(set) var detailReadState: TaskDetailReadState = .idle
    public private(set) var runHistory: [RunSummary]?
    public private(set) var historyReadState: TaskDetailReadState = .idle
    private var historyGeneration = UUID()
    private var detailEvents: [EventEnvelope] = []
    public var error: String?
    public var editorError: String?
    public private(set) var creation = TaskCreationPending()
    public private(set) var createdTaskID: TaskID?
    public private(set) var pendingRecords: [ClientCommandJournal.Record] = []
    public private(set) var visibleIDs: [ProjectID] = []
    public private(set) var recoveryCount = 0
    public private(set) var incidentReadRevision = UUID()
    private var selection = TaskDetailSelection()
    private var floors: [TaskID: Seq] = [:]
    private var schedulerFlagsSeq: Seq = 0
    private var modelFlagsSeq: Seq = 0
    private var modelCatalogSeq: Seq = 0
    private var volatileBuffer: [EphemeralEnvelope] = []
    private var epoch = UUID()
    private var lifecycle = UUID()
    private var running = false
    private var stopped = false
    private var sourceConnected = false
    private var reconciliation: Task<Void, Never>?
    private var detailRefresh: Task<Void, Never>?
    private var requestedDetailID: TaskID?
    private var reportedFailures: Set<CommandID> = []
    private var announcedCreations: Set<CommandID> = []
    private var interestedCreations: Set<CommandID> = []

    public init(client: any KabanClient, storage: any KeyValueStoring, key: String) {
        self.client = client; boardSet = BoardSetStore(storage: storage)
        do {
            let loaded = try ClientCommandJournal(storage: storage, key: key)
            journal = loaded
            drafts = try TaskDraftStore(storage: storage, key: key + ".drafts")
            interestedCreations = Set(loaded.records.filter(\.isPending).map { $0.envelope.commandId })
            reportedFailures = Set(loaded.records.filter { !$0.isPending }.map { $0.envelope.commandId })
            refreshPending()
        } catch {
            let message = "Не удалось прочитать сохранённые отправки или черновики. \(error.localizedDescription)"
            self.error = message; connectionState = .disconnected(.init(code: "client_storage_invalid", message: message))
        }
    }
    public var sessionGeneration: UUID { epoch }
    public var canSend: Bool { !stopped && connectionState == .connected && capabilities != nil && journal != nil && drafts != nil }
    public func can(_ name: CommandName) -> Bool { canSend && capabilities?.supports(name) == true }
    public func pending(in scope: CommandScope) -> ClientCommandJournal.Record? { journal?.records.first { $0.isPending && $0.scope == scope } }
    public func can(_ command: Command) -> Bool { can(command.name) && command.mutationScope.map { pending(in: $0) == nil } == true }
    public func prepareCreation() { editorError = nil; createdTaskID = nil }
    public func show(_ id: ProjectID) { boardSet.show(id); visibleIDs = boardSet.visibleProjectIds }
    public func hide(_ id: ProjectID) { boardSet.hide(id); visibleIDs = boardSet.visibleProjectIds }
    public func move(_ id: ProjectID, to index: Int) { boardSet.move(id, to: index); visibleIDs = boardSet.visibleProjectIds }
    public func show(_ id: ProjectID, at index: Int) { boardSet.show(id, at: index); visibleIDs = boardSet.visibleProjectIds }


    /// Quiesce storage writes before a runtime replaces this session/transport.
    /// Late RPC responses may finish, but cannot overwrite the next journal owner.
    public func stop() {
        stopped = true; lifecycle = UUID(); invalidate(); sourceConnected = false
        connectionState = .disconnected(.init(code: "session_stopped", message: "Соединение со службой остановлено."))
        for record in journal?.records ?? [] where record.phase == .sending {
            try? journal?.markUncertain(record.envelope.commandId)
        }
        refreshPending()
    }

    /// Cancellation is owned by BoardStore/runtime, not a SwiftUI .task lifetime.
    public func run() async {
        guard !running, journal != nil, drafts != nil else { return }
        stopped = false; running = true
        let owner = lifecycle
        defer {
            running = false; invalidate(); sourceConnected = false
        }
        var failures = 0
        while !Task.isCancelled && !stopped && owner == lifecycle {
            invalidate(); sourceConnected = false
            connectionState = projection == nil ? .connecting : .reconnecting(lastSeq: projection?.stateSeq)
            do {
                let receivedCapabilities = try await client.capabilities()
                guard !stopped, owner == lifecycle, !Task.isCancelled else { return }
                capabilities = receivedCapabilities
                guard capabilities?.supportsOperation("synchronize") == true else {
                    throw CommandError(code: CommandError.unsupportedOperationCode, message: "Служба не поддерживает восстановление сессии. Обновите Kaban.")
                }
                let stream = client.updates()
                connectionState = .synchronizing
                let replacement = try await client.synchronize()
                guard !stopped, owner == lifecycle, !Task.isCancelled else { return }
                try replace(replacement)
                for try await update in stream {
                    try Task.checkCancellation()
                    try consume(update)
                    if sourceConnected { failures = 0 }
                }
                try Task.checkCancellation()
                throw CommandError(code: "stream_closed", message: "Поток обновлений завершился.")
            } catch is CancellationError { return }
            catch {
                guard !stopped, owner == lifecycle, !Task.isCancelled else { return }
                invalidate(); sourceConnected = false; recoveryCount += 1; failures += 1
                let failure = (error as? CommandError) ?? .init(code: "transport_failure", message: "Соединение с Kaban прервано: \(error.localizedDescription)")
                if [CommandError.protocolMismatchCode, CommandError.unsupportedOperationCode, "invalid_reply"].contains(failure.code) || failures >= 5 {
                    connectionState = .disconnected(failure); return
                }
                connectionState = .reconnecting(lastSeq: projection?.stateSeq)
                do { try await Task.sleep(for: .milliseconds(200 * (1 << min(failures - 1, 4)))) }
                catch { return }
            }
        }
    }
    private func invalidate() {
        // Invalidation is logical. Cancelling a private stdio RPC stops its
        // worker/child, so routine selection/resync must not cancel shared IO.
        epoch = UUID(); reconciliation = nil; requestedDetailID = nil
        _ = selection.begin(selectedID); historyGeneration = UUID()
    }
    /// Synchronous reduction keeps the bounded stream draining during reads/replay.
    func consume(_ update: KabanClientUpdate) throws {
        guard !stopped else { return }
        switch update {
        case .capabilities(let value): capabilities = value
        case .connection(let state):
            if state == .connected {
                sourceConnected = true; startReconciliation()
            } else {
                invalidate(); sourceConnected = false; connectionState = state
            }
        case .replacement(let value):
            if let previous = ephemeralCursor, previous.sessionId != value.cursor.sessionId {
                invalidate(); sourceConnected = false; connectionState = .synchronizing
            }
            if value.cursor.sessionId == ephemeralCursor?.sessionId, let seq = projection?.stateSeq {
                if value.snapshot.seq < seq || (value.snapshot.seq == seq && value.cursor.offset < (receivedEphemeralCursor?.offset ?? 0)) { return }
                if value.cursor.offset < (ephemeralCursor?.offset ?? 0) { throw resyncError() }
            }
            try replace(value)
            if sourceConnected { startReconciliation() }
        case .event(let value):
            guard var board = projection else { throw resyncError() }
            let result = board.apply(value)
            guard result != .needsResync else { throw resyncError() }
            if case .gap = result { throw resyncError() }
            projection = board
            // Duplicate delivery may be the only retained correlation after a read.
            try journal?.observe(value)
            guard result == .applied || result == .ignored else { refreshPending(); return }
            switch value.event {
            case .incidentOpened, .incidentResolved, .projectRemoved: incidentReadRevision = UUID()
            case .taskCreated(let card), .taskEdited(let card), .taskUpdated(let card): floors[card.id] = value.seq
            case .settingsChanged(let change):
                if change.schedulerFlags != nil { schedulerFlagsSeq = value.seq }
                if change.modelFlags != nil { modelFlagsSeq = value.seq }
                if change.modelCatalog != nil { modelCatalogSeq = value.seq }
            default: break
            }
            boardSet.apply(value.event); visibleIDs = boardSet.visibleProjectIds
            if selectedProjectID.map({ board.projects[$0] == nil }) ?? true { selectedProjectID = board.projectOrder.first }
            if let id = selectedID, board.tasks[id] == nil { clearSelection() }
            refreshPending(); finishCreations(); try drainVolatile()
            if let id = selectedID, affectsDetail(value.event, taskID: id) {
                floors[id] = max(floors[id] ?? 0, value.seq)
                // Keep bounded invalidations while RPC is suspended. Do not reconstruct
                // durable feed IDs or artifacts from the retained journal.
                detailEvents.append(value)
                if detailEvents.count > DaemonWire.maxPageSize * 2 { detailEvents.removeFirst() }
                scheduleDetail(id)
            }
            if pendingRecords.contains(where: { $0.envelope.command.awaitsExternalCompletion }) { startReconciliation() }
        case .ephemeral(let value):
            guard let cursor = receivedEphemeralCursor, cursor.sessionId == value.cursor.sessionId else { throw resyncError() }
            if value.cursor.offset <= cursor.offset { return }
            // DaemonClient validates contiguous wire pages, then filters stale
            // scheduler flag envelopes. Delivered offsets may therefore skip.
            guard value.afterSeq >= 0, volatileBuffer.count < DaemonWire.maxPageSize * 2 else { throw resyncError() }
            receivedEphemeralCursor = value.cursor; volatileBuffer.append(value)
            try drainVolatile()
        }
    }
    private func resyncError() -> CommandError { .init(code: "session_resync", message: "Обновления требуют повторной синхронизации.") }
    private func replace(_ replacement: SnapshotReplacement) throws {
        guard replacement.snapshot.seq >= 0, replacement.cursor.offset >= 0,
              replacement.current.allSatisfy({ $0.cursor.sessionId == replacement.cursor.sessionId && $0.cursor.offset <= replacement.cursor.offset && $0.afterSeq <= replacement.snapshot.seq && $0.afterSeq >= 0 }) else { throw resyncError() }
        // Full replacement clears every old volatile value as well as durable cards.
        var board = BoardProjection(snapshot: replacement.snapshot)
        for current in replacement.current.sorted(by: { $0.cursor.offset < $1.cursor.offset }) {
            if replacement.snapshot.modelCatalog != nil {
                if case .modelFlagsChanged = current.event { continue }
                if case .modelCatalogChanged = current.event { continue }
            }
            if board.apply(current.event) == .resyncRequired { throw resyncError() }
        }
        projection = board; ephemeralCursor = replacement.cursor; receivedEphemeralCursor = replacement.cursor
        incidentReadRevision = UUID()
        volatileBuffer = []; schedulerFlagsSeq = replacement.snapshot.seq
        modelFlagsSeq = replacement.snapshot.seq; modelCatalogSeq = replacement.snapshot.modelCatalog == nil ? 0 : replacement.snapshot.seq
        floors = Dictionary(uniqueKeysWithValues: replacement.snapshot.tasks.map { ($0.id, replacement.snapshot.seq) })
        _ = selection.begin(selectedID); requestedDetailID = nil; detailEvents = []; historyGeneration = UUID()
        boardSet.bootstrap(projects: board.projectOrder); visibleIDs = boardSet.visibleProjectIds
        if selectedProjectID.map({ board.projects[$0] == nil }) ?? true { selectedProjectID = board.projectOrder.first }
        if let id = selectedID, board.tasks[id] == nil { clearSelection() }
        refreshPending()
        if let id = selectedID { scheduleDetail(id) }
    }
    private func drainVolatile() throws {
        while let first = volatileBuffer.first, first.afterSeq <= (projection?.stateSeq ?? -1) {
            volatileBuffer.removeFirst()
            var stale = false
            if case .schedulerFlagsChanged = first.event { stale = first.afterSeq < schedulerFlagsSeq }
            if case .modelFlagsChanged = first.event { stale = first.afterSeq < modelFlagsSeq }
            if case .modelCatalogChanged = first.event { stale = first.afterSeq < modelCatalogSeq }
            if !stale, projection?.apply(first.event) == .resyncRequired { throw resyncError() }
            ephemeralCursor = first.cursor
            if case .runProgress(let progress) = first.event,
               let id = selectedID, progress.taskId == id {
                scheduleDetail(id)
            }
        }
    }
    private func startReconciliation() {
        guard sourceConnected, reconciliation == nil else { return }
        connectionState = .synchronizing
        let generation = epoch
        reconciliation = Task { [weak self] in
            guard let self else { return }
            do {
                // Replay is identical, even when the old response was lost.
                for record in pendingRecords {
                    try Task.checkCancellation()
                    guard generation == epoch else { return }
                    guard capabilities?.supports(record.envelope.command.name) == true else {
                        throw CommandError(code: CommandError.unsupportedOperationCode, message: "Служба не может проверить сохранённую команду. Обновите Kaban; исход отправки сохранён.")
                    }
                    let reply = try await client.send(record.envelope)
                    guard generation == epoch else { return }
                    guard reply.commandId == record.envelope.commandId else { throw resyncError() }
                    try journal?.receive(reply)
                }
                let replacement = try await client.synchronize()
                guard generation == epoch, !Task.isCancelled else { return }
                // A newer journal update can arrive during this read. It already
                // covers the receipt; never roll that projection back.
                if replacement.cursor.sessionId != ephemeralCursor?.sessionId || replacement.snapshot.seq >= (projection?.stateSeq ?? 0) { try replace(replacement) }
                try journal?.confirmThrough(snapshotSeq: replacement.snapshot.seq)
                let restoreTasks = Set(journal?.records.compactMap { record -> TaskID? in
                    guard record.isPending, case .restoreWIP(let id, _, _) = record.envelope.command else { return nil }; return id
                } ?? [])
                for id in restoreTasks {
                    let reply = try await client.send(.init(command: .getTaskDetail(taskId: id)))
                    guard generation == epoch, !Task.isCancelled else { return }
                    if case .taskDetail(let value) = reply.result, value.task.id == id, value.seq >= (floors[id] ?? 0) { try journal?.observeRestores(in: value) }
                }
                refreshPending(); finishCreations(); connectionState = .connected
            } catch {
                guard generation == epoch, !Task.isCancelled else { return }
                // Pending remains saved. Stop accepting new mutations until a
                // new connected handshake (or explicit retry) reconciles it.
                connectionState = .disconnected((error as? CommandError) ?? .init(code: "reconciliation_failed", message: "Не удалось проверить сохранённые отправки. \(error.localizedDescription)"))
                sourceConnected = false
            }
            if generation == epoch { reconciliation = nil }
        }
    }
    private func refreshPending() {
        pendingRecords = journal?.records.filter(\.isPending) ?? []
        for record in journal?.records ?? [] where !record.isPending && !reportedFailures.contains(record.envelope.commandId) {
            let message: String?
            switch record.phase {
            case .effectFailed(let failure), .rejected(let failure): message = failure.message
            case .superseded: message = "Восстановление WIP отменено другим действием с задачей."
            default: message = nil
            }
            if let message {
                // The addressed answer composer presents its own durable receipt
                // beside the retained text. A modal alert would cover the new question.
                switch record.envelope.command {
                case .answerHuman, .approve, .requestChanges, .reject: break
                default: error = message; editorError = message
                }
                reportedFailures.insert(record.envelope.commandId)
            }
        }
        var marks = PendingCommands()
        for record in pendingRecords {
            if case .task(let id) = record.scope { marks.markSent(commandId: record.envelope.commandId, taskId: id, at: record.sentAt) }
        }
        projection?.replacePending(marks)
        creation = TaskCreationPending()
        if let record = pendingRecords.first(where: { if case .createTask = $0.envelope.command { return true }; return false }),
           case .createTask(let id, _, _) = record.envelope.command { _ = creation.begin(commandID: record.envelope.commandId, projectID: id) }
    }
    private func finishCreations() {
        for record in journal?.records ?? [] where !record.isPending {
            let id = record.envelope.commandId
            if record.phase == .applied { try? drafts?.confirmed(id) }
            guard interestedCreations.contains(id), !announcedCreations.contains(id), record.phase == .applied,
                  case .createTask(let project, _, _) = record.envelope.command else { continue }
            let taskID: TaskID?
            if case .taskCreated(let value) = record.reply?.result { taskID = value }
            else { taskID = record.createdTaskID }
            guard let taskID, projection?.tasks[taskID]?.projectId == project else { continue }
            announcedCreations.insert(id); createdTaskID = taskID; selectedProjectID = project; show(project)
            selectedID = taskID; scheduleDetail(taskID)
        }
    }
    public func select(_ id: TaskID?) async {
        selectedID = id; detail = nil; detailEvents = []; detailReadState = .idle
        runHistory = nil; historyReadState = .idle; historyGeneration = UUID(); _ = selection.begin(id)
        if let id { await refreshDetail(id) }
    }
    private func clearSelection() { selectedID = nil; detail = nil; detailEvents = []; detailReadState = .idle; runHistory = nil; historyReadState = .idle; historyGeneration = UUID(); _ = selection.begin(nil); requestedDetailID = nil }
    private func scheduleDetail(_ id: TaskID) {
        detailReadState = .loading
        requestedDetailID = id
        guard detailRefresh == nil else { return }
        detailRefresh = Task { [weak self] in
            guard let self else { return }
            while let wanted = requestedDetailID {
                requestedDetailID = nil
                await refreshDetail(wanted)
            }
            detailRefresh = nil
        }
    }
    private func refreshDetail(_ id: TaskID) async {
        guard !stopped, selectedID == id else { return }
        guard capabilities?.supports(.getTaskDetail) == true else {
            detailReadState = .unavailable(.init(code: CommandError.unsupportedOperationCode, message: "Служба не поддерживает чтение деталей задачи."))
            return
        }
        detailReadState = .loading
        let generation = selection.begin(id); let session = epoch
        do {
            let envelope = CommandEnvelope(command: .getTaskDetail(taskId: id))
            let reply = try await client.send(envelope)
            guard session == epoch, selection.accepts(generation, taskID: id), !Task.isCancelled else { return }
            guard reply.commandId == envelope.commandId else { throw resyncError() }
            switch reply.result {
            case .taskDetail(let value):
                guard selection.accepts(generation, detail: value, minimumSeq: max(max(floors[id] ?? 0, detail?.seq ?? 0), detailEvents.last?.seq ?? 0)) else {
                    if requestedDetailID == nil {
                        detailReadState = .unavailable(.init(code: "stale_detail", message: "Служба вернула устаревшие детали. Обновите их ещё раз."))
                    }
                    return
                }
                // Only a read covering all buffered invalidations can publish durable
                // history. Anything after its seq is covered by the coalesced next read.
                detailEvents.removeAll { $0.seq <= value.seq }
                detail = TaskDetailPresentation.normalized(value); detailReadState = .loaded
                try journal?.observeRestores(in: value); refreshPending()
            case .error(let failure): detailReadState = .unavailable(failure)
            default: detailReadState = .unavailable(.init(code: "invalid_reply", message: "Не удалось получить детали задачи."))
            }
        } catch {
            guard session == epoch, selection.accepts(generation, taskID: id), !Task.isCancelled else { return }
            detailReadState = .unavailable((error as? CommandError) ?? .init(code: "detail_read_failed", message: error.localizedDescription))
        }
    }
    public func retryDetail() async {
        guard let id = selectedID else { return }
        await refreshDetail(id)
    }
    public func readRunHistory() async {
        guard let id = selectedID, !stopped else { return }
        guard capabilities?.supports(.getRunHistory) == true else {
            historyReadState = .unavailable(.init(code: CommandError.unsupportedOperationCode, message: "Служба не поддерживает отдельную историю запусков."))
            return
        }
        let owner = epoch, generation = UUID(); historyGeneration = generation; historyReadState = .loading
        let envelope = CommandEnvelope(command: .getRunHistory(taskId: id))
        do {
            let reply = try await client.send(envelope)
            guard !stopped, selectedID == id, owner == epoch, generation == historyGeneration else { return }
            guard reply.commandId == envelope.commandId else { throw resyncError() }
            switch reply.result {
            case .runs(let runs):
                guard runs.allSatisfy({ $0.taskId == id }) else { throw resyncError() }
                runHistory = runs.sorted { ($0.startedAt, $0.id.rawValue) < ($1.startedAt, $1.id.rawValue) }
                historyReadState = .loaded
            case .error(let failure): historyReadState = .unavailable(failure)
            default: throw resyncError()
            }
        } catch {
            guard !stopped, selectedID == id, owner == epoch, generation == historyGeneration else { return }
            historyReadState = .unavailable((error as? CommandError) ?? .init(code: "history_read_failed", message: error.localizedDescription))
        }
    }
    private func affectsDetail(_ event: JournalEvent, taskID: TaskID) -> Bool {
        switch event {
        case .taskCreated(let card), .taskUpdated(let card), .taskEdited(let card): card.id == taskID
        case .taskTransitioned(let value): value.taskId == taskID
        case .humanRequested(let value): value.taskId == taskID
        case .humanAnswered(let value): value.taskId == taskID
        case .gitDenied(let value): value.taskId == taskID
        case .incidentOpened(let value): value.taskId == taskID
        case .suspiciousFilesFound(let value): value.taskId == taskID
        case .suspiciousFilesAccepted(let value): value.taskId == taskID
        case .wipRestored(let value): value.taskId == taskID
        // These payloads omit taskId. A full selected-task read safely resolves
        // ownership, including a grant/incident that arrived during the first read.
        case .gitGrantCreated, .gitGrantDelivered, .gitGrantConsumed, .gitGrantRevoked, .gitGrantExpired, .incidentResolved, .unknown: true
        default: false
        }
    }
    @discardableResult public func send(_ command: Command, editor: Bool = false) async -> Bool {
        await send(CommandEnvelope(command: command), editor: editor)
    }
    @discardableResult public func send(_ envelope: CommandEnvelope, editor: Bool = false) async -> Bool {
        let command = envelope.command
        guard can(command), let journal else { return false }
        let owner = lifecycle
        do { try journal.begin(envelope) }
        catch { self.error = error.localizedDescription; return false }
        if case .createTask(let project, _, _) = command {
            interestedCreations.insert(envelope.commandId); try? drafts?.submitted(.create(project), by: envelope.commandId)
        } else if case .editTask(let id, _, let body) = command,
                  body != nil || drafts?.record(for: .edit(id))?.exactBody == nil {
            // Title-only submission must not discard a body draft that wasn't sent.
            try? drafts?.submitted(.edit(id), by: envelope.commandId)
        }
        if case .setPriority(let id, _) = command { try? drafts?.submitted(.priority(id), by: envelope.commandId) }
        refreshPending()
        do {
            let reply = try await client.send(envelope)
            guard owner == lifecycle else { return false }
            guard reply.commandId == envelope.commandId else { throw resyncError() }
            try journal.receive(reply); refreshPending(); finishCreations()
            if case .error(let failure) = reply.result {
                if editor { editorError = failure.message } else { error = failure.message }; return false
            }
            if journal.records.first(where: { $0.envelope.commandId == envelope.commandId })?.isPending == true { startReconciliation() }
            return true
        } catch {
            guard owner == lifecycle else { return false }
            if let record = journal.records.first(where: { $0.envelope.commandId == envelope.commandId }), !record.isPending {
                refreshPending(); finishCreations()
                return record.phase == .applied
            }
            try? journal.markUncertain(envelope.commandId); refreshPending()
            let message = "Исход отправки пока неизвестен. Сохранённую команду проверим после подключения."
            if editor { editorError = message } else { self.error = message }
            startReconciliation(); return false
        }
    }
}
