import Foundation
import KabanProtocol

/// All adapters enter the same durable command boundary. No adapter reduces tasks.
public struct DaemonService: Sendable {
    public let store: KabanStore
    public init(store: KabanStore) { self.store = store }

    public func handle(_ request: DaemonRequest) -> DaemonResponse {
        guard request.protocolVersion == KabanCoding.protocolVersion else {
            return .init(.error(.init(code: CommandError.protocolMismatchCode, message: "Несовместимая версия протокола.")))
        }
        do {
            switch request.operation {
            case .snapshot: return .init(.snapshot(try store.getSnapshot()))
            case .subscribe(let seq, let limit): return .init(.events(try store.journalPage(after: seq, limit: limit)))
            case .command(let envelope): return .init(.command(try store.execute(envelope)))
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
