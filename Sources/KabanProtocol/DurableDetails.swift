import Foundation

/// Initial and updated global configuration; scheduler flags remain in Snapshot.schedulerFlags.
/// Required values are supplied by the daemon rather than inferred by the client.
public struct GlobalSettings: Codable, Hashable, Sendable {
    public var maxConcurrentRuns: Int
    public var quotaOptions: QuotaOptions
    public var quotaConsentedAt: Date?
    public init(maxConcurrentRuns: Int, quotaOptions: QuotaOptions, quotaConsentedAt: Date? = nil) {
        self.maxConcurrentRuns = maxConcurrentRuns; self.quotaOptions = quotaOptions; self.quotaConsentedAt = quotaConsentedAt
    }
}

/// Durable stage output. kind is open: summary, diffstat, gate_output, or a future kind.
/// path is optional local metadata, never a credential or an authorization to read a file.
public struct TaskArtifact: Codable, Hashable, Sendable {
    public var id: ArtifactID
    public var taskId: TaskID
    public var runId: RunID?
    public var stageId: StageID?
    public var kind: String
    public var text: String
    public var createdAt: Date
    public var path: String?
    public init(id: ArtifactID, taskId: TaskID, runId: RunID? = nil, stageId: StageID? = nil,
                kind: String, text: String, createdAt: Date, path: String? = nil) {
        self.id = id; self.taskId = taskId; self.runId = runId; self.stageId = stageId
        self.kind = kind; self.text = text; self.createdAt = createdAt; self.path = path
    }
}

/// Durable denial; retains the same payload as gitDenied plus its original event time.
public struct GitDenialSnapshot: Codable, Hashable, Sendable {
    public var denial: GitDenied
    public var at: Date
    public init(denial: GitDenied, at: Date) { self.denial = denial; self.at = at }
}

/// Durable grant lifecycle, independent of journal retention. Payloads reuse journal DTOs.
/// Delivery does not consume a grant. Consumed/revoked/expired grants cannot authorize execution.
/// The daemon enforces matching task/stage/argv and hard invariants; no run token is exposed here.
public struct GitGrantSnapshot: Codable, Hashable, Sendable {
    public var grant: GitGrantCreated
    public var taskId: TaskID
    public var stageId: StageID
    public var createdAt: Date
    public var delivery: GitGrantDelivered?
    public var deliveredAt: Date?
    public var consumption: GitGrantRef?
    public var consumedAt: Date?
    public var revocation: GitGrantRevoked?
    public var revokedAt: Date?
    public var expiry: GitGrantExpired?
    public var expiredAt: Date?
    public init(grant: GitGrantCreated, taskId: TaskID, stageId: StageID, createdAt: Date,
                delivery: GitGrantDelivered? = nil, deliveredAt: Date? = nil,
                consumption: GitGrantRef? = nil, consumedAt: Date? = nil,
                revocation: GitGrantRevoked? = nil, revokedAt: Date? = nil,
                expiry: GitGrantExpired? = nil, expiredAt: Date? = nil) {
        self.grant = grant; self.taskId = taskId; self.stageId = stageId; self.createdAt = createdAt
        self.delivery = delivery; self.deliveredAt = deliveredAt; self.consumption = consumption; self.consumedAt = consumedAt
        self.revocation = revocation; self.revokedAt = revokedAt; self.expiry = expiry; self.expiredAt = expiredAt
    }
}
