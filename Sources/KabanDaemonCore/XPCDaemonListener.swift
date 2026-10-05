#if os(macOS)
import Foundation
import XPC
import KabanProtocol

@available(macOS 26.0, *)
public final class XPCDaemonListener {
    private let listener: XPCListener

    /// There is no unsigned Mach-service mode. Development uses a private stdio channel.
    public init(service: DaemonService, name: String = DaemonWire.machService) throws {
        listener = try XPCListener(service: name, requirement: .isFromSameTeam()) { request in
            request.accept { (data: Data) in service.handle(data: data) }
        }
    }
    public func cancel() { listener.cancel() }
}
#endif
