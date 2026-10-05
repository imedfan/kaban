import Foundation
import KabanProtocol

/// All adapters enter the same durable command boundary. No adapter reduces tasks.
public struct DaemonService: Sendable {
    public let store: KabanStore
    public let liveEvents: DaemonLiveEvents
    public init(store: KabanStore, liveEvents: DaemonLiveEvents = .init()) {
        self.store = store; self.liveEvents = liveEvents
    }

    /// Future producers publish through this boundary after durable commit. No fake runner,
    /// catalog, quota or log data is synthesized when a producer is unavailable.
    public func publishEphemeral(_ event: EphemeralEvent, at: Date = Date()) throws {
        try liveEvents.publish(event, at: at) { try store.getSnapshot().seq }
    }

    public func handle(_ request: DaemonRequest) -> DaemonResponse {
        guard request.protocolVersion == KabanCoding.protocolVersion else {
            return .init(.error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        do {
            switch request.operation {
            case .snapshot: return .init(.snapshot(try store.getSnapshot()))
            case .subscribe(let seq, let limit): return .init(.events(try store.journalPage(after: seq, limit: limit)))
            case .command(let envelope): return .init(.command(try store.execute(envelope)))
            case .capabilities: return .init(.capabilities(Self.capabilities))
            case .synchronize: return .init(.replacement(try liveEvents.synchronize { try store.getSnapshot() }))
            case .ephemeral(let cursor, let limit): return .init(.ephemeral(try liveEvents.page(after: cursor, limit: limit)))
            case .readLog(_, let offset, let limit):
                guard offset >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
                    throw CommandError(code: "invalid_request", message: "Некорректное смещение или размер пакета лога.")
                }
                throw CommandError(code: CommandError.unsupportedOperationCode, message: "Чтение логов ещё не поддерживается этим backend.", params: ["operation": "readLog"])
            }
        } catch let error as CommandError {
            return .init(.error(error))
        } catch StoreError.incompleteProjection {
            return .init(.error(.init(code: "incomplete_projection", message: "Сохранённые данные не содержат полной проекции.")))
        } catch {
            // SQL, repository paths and internal exception text never cross the process boundary.
            return .init(.error(.init(code: "storage_failure", message: "Не удалось выполнить операцию с хранилищем. Повторите запрос.")))
        }
    }

    public static var capabilities: DaemonCapabilities {
        .init(operations: ["snapshot", "subscribe", "command", "capabilities", "synchronize", "ephemeral", "readLog"].map {
            .init(name: $0, supported: $0 != "readLog")
        }, commands: CommandName.allCases.map { .init(name: $0.rawValue, support: support($0), scopes: $0 == .recheck ? ["project"] : nil) })
    }
    private static func support(_ command: CommandName) -> CommandSupport {
        switch command {
        case .pauseAll, .resumeAll, .setMaxConcurrentRuns, .setQuotaOptions,
             .addProject, .removeProject, .relinkProject, .listBranches, .detectGates, .recheck,
             .createTask, .editTask, .setPriority, .cancelTask, .getTaskDetail, .getRunHistory,
             .pauseProject, .resumeProject, .setMascot, .setProjectWeight, .setProjectIdentity,
             .validatePipeline, .validatePipelineDraft, .updatePipeline: .supported
        case .moveTask, .pauseTask, .resumeTask, .retryStage, .answerHuman, .approve, .requestChanges, .reject: .managedFakeOnly
        case .setModelOverride, .restoreWIP, .acceptSuspiciousFiles, .allowGitOnce, .addDenialToPolicy,
             .revokeGitGrant, .resumeAfterRateLimit, .checkEnvironment, .getCursorEnvironment,
             .configureCursor, .listModels, .refreshModelCatalog, .setModelPoolRule,
             .removeModelPoolRule, .clearModelFlag, .listProjectMcpServers, .setProjectMcpAllowlist,
             .listIncidents: .unsupported
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
