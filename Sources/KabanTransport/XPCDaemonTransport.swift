#if os(macOS)
import Foundation
import XPC
import KabanProtocol

@available(macOS 26.0, *)
public actor XPCDaemonTransport: DaemonTransport {
    private let makeSession: @Sendable () throws -> XPCSession
    private let timeout: TimeInterval
    private var session: XPCSession?

    public init(machService: String = DaemonWire.machService, timeout: TimeInterval = 10) {
        makeSession = { try XPCSession(machService: machService, requirement: .isFromSameTeam()) }
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 60) : 10
    }
    // A private, unregistered endpoint is used by integration tests only.
    init(endpoint: XPCEndpoint, timeout: TimeInterval = 10) {
        makeSession = { try XPCSession(endpoint: endpoint) }
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 60) : 10
    }

    public func exchange(_ request: DaemonRequest) async throws -> DaemonResponse {
        try Task.checkCancellation()
        let payload = try DaemonWire.encode(request)
        let current: XPCSession
        do {
            if let session { current = session }
            else { current = try makeSession(); session = current }
        } catch { throw DaemonTransportError.connectionLost }
        let completion = RPCCompletion()
        do {
            let data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    guard !completion.isFinished else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak completion] in
                        completion?.finish(.failure(DaemonTransportError.timedOut))
                    }
                    do {
                        try current.send(payload) { (reply: Result<XPCReceivedMessage, XPCRichError>) in
                            switch reply {
                            case .success(let message):
                                do { completion.finish(.success(try message.decode(as: Data.self))) }
                                catch { completion.finish(.failure(DaemonTransportError.invalidReply)) }
                            case .failure: completion.finish(.failure(DaemonTransportError.connectionLost))
                            }
                        }
                    } catch { completion.finish(.failure(DaemonTransportError.connectionLost)) }
                }
            } onCancel: { completion.finish(.failure(CancellationError())) }
            do { return try DaemonWire.decode(DaemonResponse.self, from: data) }
            catch { throw DaemonTransportError.invalidReply }
        } catch {
            if session === current {
                session = nil
                current.cancel(reason: "Request ended without a usable reply")
            }
            throw error
        }
    }
    public func close() {
        session?.cancel(reason: "Client closed")
        session = nil
    }
}

#endif
