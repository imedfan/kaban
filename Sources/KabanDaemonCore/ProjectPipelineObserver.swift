#if os(macOS)
import Foundation
import CoreServices

/// Watches project roots so deleting or recreating .kaban is observable too. The host's bounded
/// polling remains a fallback for dropped events, missing roots and newly registered projects.
public final class ProjectPipelineObserver: @unchecked Sendable {
    private final class Callback: @unchecked Sendable {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.kaban.pipeline-fsevents")
    private let changed: @Sendable () -> Void
    private var paths: [String] = []
    private var stream: FSEventStreamRef?

    public init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    deinit { stop() }

    public func watch(projectPaths: [String]) {
        lock.lock(); defer { lock.unlock() }
        let next = Array(Set(projectPaths)).sorted()
        guard next != paths else { return }
        closeStream(); paths = next
        guard !next.isEmpty else { return }
        let callback = Callback(changed)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<Callback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let created = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let mustRescan = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 }
            if mustRescan || paths.contains(where: { $0.split(separator: "/").contains(".kaban") }) {
                callback.changed()
            }
        }, &context, next as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        withExtendedLifetime(callback) {}
        guard let created else { paths = []; return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) { closeStream(); paths = [] }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        closeStream(); paths = []
    }
    private func closeStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
#endif
