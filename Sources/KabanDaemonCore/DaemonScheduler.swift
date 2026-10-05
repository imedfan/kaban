import Foundation
import Dispatch

/// Serial, coalesced wakes plus a one-second retry fallback. Each wake has a finite budget;
/// external effects are only enqueued by the store, never executed by this loop.
public final class DaemonScheduler: @unchecked Sendable {
    private let store: KabanStore
    private let queue = DispatchQueue(label: "app.kaban.scheduler")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var stopped = false
    private var pending = false
    private let timer: DispatchSourceTimer
    private let onError: @Sendable (Error) -> Void

    public init(store: KabanStore, onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.store = store; self.onError = onError
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
                do { _ = try self.store.runSchedulerPass(at: Date()) }
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
