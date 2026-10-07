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
    public var error: String?
    public var editorError: String?
    public private(set) var creation = TaskCreationPending()
    public private(set) var createdTaskID: TaskID?
    public private(set) var pendingRecords: [ClientCommandJournal.Record] = []
    public private(set) var visibleIDs: [ProjectID] = []
    public private(set) var recoveryCount = 0
    private var selection = TaskDetailSelection()
    private var floors: [TaskID: Seq] = [:]
    private var schedulerFlagsSeq: Seq = 0
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
        _ = selection.begin(selectedID)
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
            case .taskCreated(let card), .taskEdited(let card), .taskUpdated(let card): floors[card.id] = value.seq
            case .settingsChanged(let change) where change.schedulerFlags != nil: schedulerFlagsSeq = value.seq
            default: break
            }
            boardSet.apply(value.event); visibleIDs = boardSet.visibleProjectIds
            if selectedProjectID.map({ board.projects[$0] == nil }) ?? true { selectedProjectID = board.projectOrder.first }
            if let id = selectedID, board.tasks[id] == nil { clearSelection() }
            refreshPending(); finishCreations(); try drainVolatile()
            if let id = selectedID, floors[id] == value.seq { scheduleDetail(id) }
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
            if board.apply(current.event) == .resyncRequired { throw resyncError() }
        }
        projection = board; ephemeralCursor = replacement.cursor; receivedEphemeralCursor = replacement.cursor
        volatileBuffer = []; schedulerFlagsSeq = replacement.snapshot.seq
        floors = Dictionary(uniqueKeysWithValues: replacement.snapshot.tasks.map { ($0.id, replacement.snapshot.seq) })
        _ = selection.begin(selectedID); requestedDetailID = nil; detail = nil
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
            if !stale, projection?.apply(first.event) == .resyncRequired { throw resyncError() }
            ephemeralCursor = first.cursor
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
            if let message { error = message; editorError = message; reportedFailures.insert(record.envelope.commandId) }
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
        selectedID = id; detail = nil; _ = selection.begin(id)
        if let id { await refreshDetail(id) }
    }
    private func clearSelection() { selectedID = nil; detail = nil; _ = selection.begin(nil); requestedDetailID = nil }
    private func scheduleDetail(_ id: TaskID) {
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
        guard !stopped, selectedID == id, capabilities?.supports(.getTaskDetail) == true else { return }
        let generation = selection.begin(id); let session = epoch
        do {
            let reply = try await client.send(.init(command: .getTaskDetail(taskId: id)))
            guard session == epoch, selection.accepts(generation, taskID: id), !Task.isCancelled else { return }
            switch reply.result {
            case .taskDetail(let value):
                guard selection.accepts(generation, detail: value, minimumSeq: max(floors[id] ?? 0, detail?.seq ?? 0)) else { return }
                detail = value; try journal?.observeRestores(in: value); refreshPending()
            case .error(let failure): error = failure.message
            default: error = "Не удалось получить детали задачи."
            }
        } catch {
            guard session == epoch, selection.accepts(generation, taskID: id), !Task.isCancelled else { return }
            self.error = error.localizedDescription
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
