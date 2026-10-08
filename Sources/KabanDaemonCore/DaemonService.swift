import Foundation
import KabanProtocol

/// All adapters enter the same durable command boundary. No adapter reduces tasks.
public struct DaemonService: Sendable {
    public let store: KabanStore
    public let liveEvents: DaemonLiveEvents
    private let wakeScheduler: @Sendable () -> Void
    public init(store: KabanStore, liveEvents: DaemonLiveEvents = .init(), wakeScheduler: @escaping @Sendable () -> Void = {}) {
        self.store = store; self.liveEvents = liveEvents; self.wakeScheduler = wakeScheduler
    }

    /// Future producers publish through this boundary after durable commit. No fake runner,
    /// catalog, quota or log data is synthesized when a producer is unavailable.
    public func publishEphemeral(_ event: EphemeralEvent, at: Date = Date()) throws {
        try liveEvents.publish(event, at: at) { try store.getSnapshot().seq }
    }

    /// Producer facts commit before live delivery/wake. A reconnect recovers them from snapshot.
    public func updateSchedulerInputs(_ inputs: SchedulerInputs, commandId: CommandID, at: Date) throws -> ConfigurationReceipt {
        store.projectOperations.lock(); defer { store.projectOperations.unlock() }
        let previousQuota = try store.getSnapshot().quota
        let receipt = try store.setSchedulerInputs(inputs, commandId: commandId, at: at)
        let snapshot = try store.getSnapshot()
        try publishEphemeral(.modelFlagsChanged(snapshot.modelFlags), at: at)
        if let quota = snapshot.quota { try publishEphemeral(.quotaUpdated(quota), at: at) }
        else if previousQuota != nil {
            liveEvents.discardQuota()
            try publishEphemeral(.resyncRequired, at: at)
        }
        wakeScheduler()
        return receipt
    }

    public func handle(_ request: DaemonRequest) -> DaemonResponse {
        guard request.protocolVersion == KabanCoding.protocolVersion else {
            return .init(.error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        do {
            switch request.operation {
            case .snapshot: return .init(.snapshot(try store.getSnapshot()))
            case .subscribe(let seq, let limit): return .init(.events(try store.journalPage(after: seq, limit: limit)))
            case .command(let envelope):
                let reply = try store.execute(envelope)
                if reply.seq != nil { wakeScheduler() }
                return .init(.command(reply))
            case .capabilities: return .init(.capabilities(Self.capabilities))
            case .synchronize: return .init(.replacement(try liveEvents.synchronize { try store.getSnapshot() }))
            case .ephemeral(let cursor, let limit): return .init(.ephemeral(try liveEvents.page(after: cursor, limit: limit)))
            case .readLog(let runId, let offset, let limit):
                return .init(.log(try store.readLog(runId: runId, fromOffset: offset, limit: limit)))
            }
        } catch let error as CommandError {
            return .init(.error(error))
        } catch StoreError.incompleteProjection {
            return .init(.error(.init(code: "incomplete_projection", message: "Сохранённые данные не содержат полной проекции.")))
        } catch StoreError.rejected(let error) {
            return .init(.error(error))
        } catch {
            // SQL, repository paths and internal exception text never cross the process boundary.
            return .init(.error(.init(code: "storage_failure", message: "Не удалось выполнить операцию с хранилищем. Повторите запрос.")))
        }
    }

    public static var capabilities: DaemonCapabilities {
        .init(operations: ["snapshot", "subscribe", "command", "capabilities", "synchronize", "ephemeral", "readLog"].map {
            .init(name: $0, supported: true)
        }, commands: CommandName.allCases.map { .init(name: $0.rawValue, support: support($0), scopes: $0 == .recheck ? ["project", "runner"] : nil) })
    }
    private static func support(_ command: CommandName) -> CommandSupport {
        switch command {
        case .pauseAll, .resumeAll, .setMaxConcurrentRuns, .setQuotaOptions,
             .addProject, .removeProject, .relinkProject, .listBranches, .detectGates, .recheck,
             .createTask, .editTask, .setPriority, .cancelTask, .getTaskDetail, .getRunHistory,
             .pauseProject, .resumeProject, .setMascot, .setProjectWeight, .setProjectIdentity,
             .validatePipeline, .validatePipelineDraft, .getPipelineSource, .updatePipeline,
             .moveTask, .pauseTask, .resumeTask, .retryStage, .answerHuman, .approve, .requestChanges, .reject,
             .restoreWIP, .setModelOverride, .listModels, .refreshModelCatalog, .setModelPoolRule, .removeModelPoolRule, .clearModelFlag,
             .resumeAfterRateLimit, .allowGitOnce, .addDenialToPolicy, .revokeGitGrant,
             .acceptSuspiciousFiles, .listIncidents: .supported
        case .checkEnvironment, .getCursorEnvironment,
             .configureCursor, .listProjectMcpServers, .setProjectMcpAllowlist: .unsupported
        }
    }

    public func handle(data: Data) -> Data {
        let response: DaemonResponse
        do { response = handle(try DaemonWire.decode(DaemonRequest.self, from: data)) }
        catch { response = .init(.error(.init(code: "invalid_request", message: "Некорректное сообщение."))) }
        do { return try DaemonWire.encode(response) }
        catch {
            // A large snapshot/detail must fail explicitly, never silently truncate state.
            return try! DaemonWire.encode(DaemonResponse(.error(.init(code: "response_too_large", message: "Ответ превышает лимит сообщения."))))
        }
    }
}
