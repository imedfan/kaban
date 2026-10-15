#if os(macOS)
import Foundation
import XPC
import KabanProtocol
import KabanTransport

@available(macOS 26.0, *)
public final class XPCDaemonListener {
    private let listener: XPCListener

    /// Bundled Apple signatures use same-team + ID. Personal builds pin the peer hash.
    public init(service: DaemonService, name: String = DaemonWire.machService) throws {
        guard let executable = Bundle.main.executableURL else { throw BundledDaemonIdentity.Failure.notBundled }
        let bundle = try BundledDaemonIdentity.appBundle(containing: executable)
        let requirement = try BundledDaemonIdentity.requirement(appBundle: bundle, forHelper: false)
        listener = try XPCListener(service: name, requirement: requirement) { request in
            request.accept { (data: Data) in service.handle(data: data) }
        }
    }
    public func cancel() { listener.cancel() }
}
#endif
