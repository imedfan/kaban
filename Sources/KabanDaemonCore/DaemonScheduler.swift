import Foundation
import Dispatch

/// Serial, coalesced wakes plus a one-second retry fallback. Each wake has a finite budget;
/// Production wakes drain manual effects before admitting another invocation.
public final class DaemonScheduler: @unchecked Sendable {
    private let store: KabanStore
    private let workspaceRoot: String?
    private let runner: String?
    private let runnerArguments: [String]
    private let queue = DispatchQueue(label: "app.kaban.scheduler")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var stopped = false
    private var pending = false
    private let timer: DispatchSourceTimer
    private let onError: @Sendable (Error) -> Void

    public init(store: KabanStore, workspaceRoot: String? = nil, runner: String? = nil, runnerArguments: [String] = [], onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.store = store; self.onError = onError
        self.workspaceRoot = workspaceRoot; self.runner = runner; self.runnerArguments = runnerArguments
        queue.setSpecific(key: queueKey, value: 1)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.wake() }
        timer.resume()
        wake()
    }
    public func wake() {
        lock.lock()
        guard !stopped, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let cancelled = self.stopped; self.lock.unlock()
            if !cancelled {
                do {
                    if let root = self.workspaceRoot {
                        try self.store.runRuntimePass(at: Date(), workspaceRoot: root, runner: self.runner, runnerArguments: self.runnerArguments)
                    } else { _ = try self.store.runSchedulerPass(at: Date()) }
                }
                catch { self.onError(error) }
            }
            self.lock.lock(); self.pending = false; self.lock.unlock()
        }
    }
    /// Wait for an in-flight pass before releasing the daemon's database lease.
    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        timer.cancel()
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }
    deinit { timer.cancel() }
}
