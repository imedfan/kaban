import Foundation
import KabanKit

extension KabanStore {
    /// Serialized with wire commands: stop/WIP/cleanup and restored context precede admission.
    /// A configured local runner is opt-in; absent runner keeps Cursor starts pending.
    public func runRuntimePass(at: Date, workspaceRoot: String, runner: String? = nil, runnerArguments: [String] = []) throws {
        projectOperations.lock(); defer { projectOperations.unlock() }
        _ = try recoverEffectExecution(at: at, reclaimUnexpired: false)
        _ = try runProcessPass(owner: "runtime", at: at, workspaceRoot: workspaceRoot, runner: nil)
        _ = try runWIPRestorePass(owner: "runtime", at: at)
        _ = try runStagePass(owner: "runtime", at: at)
        _ = try runMergePass(owner: "runtime", at: at, workspaceRoot: workspaceRoot)
        _ = try runClonePass(owner: "runtime", at: at, workspaceRoot: workspaceRoot)
        for item in try pendingEffectItems() {
            switch item.effect {
            case .scheduleRetry, .expireGitGrants, .notifyHuman:
                // Retry time, grant revocation and human notification are already durable
                // store/journal facts. There is no simulated file or external notification.
                if let lease = try claimEffect(id: item.id, owner: "runtime", at: at) {
                    _ = try commitEffectResult(effectId: item.id, leaseId: lease.leaseId,
                        fact: .init(actionId: item.id + "/durable", phase: .finished, outcome: .acknowledged), at: at)
                }
            default: break
            }
        }
        _ = try runSchedulerPass(at: at)
        _ = try runClonePass(owner: "runtime", at: at, workspaceRoot: workspaceRoot)
        _ = try runProcessPass(owner: "runtime", at: at, workspaceRoot: workspaceRoot, runner: runner, runnerArguments: runnerArguments)
    }
}
