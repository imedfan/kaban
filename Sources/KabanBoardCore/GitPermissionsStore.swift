import Foundation
import Observation
import KabanProtocol

@MainActor @Observable public final class GitPermissionsStore {
    private let client: any KabanClient
    private let session: BoardSession
    public var preview: GitPolicyPreviewStore?

    public init(client: any KabanClient, session: BoardSession) {
        self.client = client; self.session = session
    }
    public var detail: TaskDetail? {
        guard let detail = session.detail, session.selectedID == detail.task.id else { return nil }
        return detail
    }
    public func receipt(in scope: CommandScope) -> ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return session.journal?.records.last { $0.scope == scope }
    }
    public func canAllow(_ denial: GitDenialSnapshot) -> Bool {
        guard session.detailReadState == .loaded, let detail,
              detail.gitDenials.contains(denial), denial.context?.stageId != nil,
              denial.context?.restriction == nil,
              !detail.gitGrants.contains(where: { $0.grant.denialId == denial.denial.denialId }) else { return false }
        return session.can(.allowGitOnce(denialId: denial.denial.denialId))
    }
    public func allow(_ denial: GitDenialSnapshot) async {
        guard canAllow(denial) else { return }
        _ = await session.send(.allowGitOnce(denialId: denial.denial.denialId))
    }
    public func canRevoke(_ grant: GitGrantSnapshot) -> Bool {
        session.detailReadState == .loaded && detail?.gitGrants.contains(grant) == true
            && grant.consumption == nil && grant.revocation == nil && grant.expiry == nil
            && session.can(.revokeGitGrant(grantId: grant.grant.grantId))
    }
    public func revoke(_ grant: GitGrantSnapshot) async {
        guard canRevoke(grant) else { return }
        _ = await session.send(.revokeGitGrant(grantId: grant.grant.grantId))
    }
    public func canPreview(_ denial: GitDenialSnapshot) -> Bool {
        guard session.detailReadState == .loaded, let detail, detail.gitDenials.contains(denial),
              let context = denial.context, context.stageId != nil, context.restriction == nil,
              !context.policyRule.isEmpty, session.pending(in: .denial(denial.denial.denialId)) == nil else { return false }
        return session.can(.addDenialToPolicy) && session.can(.getPipelineSource)
    }
    public func openPreview(_ denial: GitDenialSnapshot) {
        guard canPreview(denial), let detail else { return }
        preview = .init(denial: denial, taskID: detail.task.id, projectID: detail.task.projectId, client: client, session: session)
    }
}

@MainActor @Observable public final class GitPolicyPreviewStore: Identifiable {
    public let id = UUID()
    public let denial: GitDenialSnapshot
    public let taskID: TaskID
    public let editor: PipelineEditorStore
    public private(set) var scope: PolicyScope = .project
    public private(set) var error: String?
    private let session: BoardSession
    private var baseline: String?

    public init(denial: GitDenialSnapshot, taskID: TaskID, projectID: ProjectID,
                client: any KabanClient, session: BoardSession) {
        self.denial = denial; self.taskID = taskID; self.session = session
        editor = .init(projectID: projectID, client: client, session: session)
    }
    public var policy: EffectiveGitPolicy? {
        switch scope {
        case .project: editor.lastResolved?.projectGitPolicy
        case .stage(let id): editor.lastResolved?.stages.first { $0.id == id }?.gitPolicy
        }
    }
    public var ruleAllowed: Bool {
        policy?.allowed.contains { $0.rule == denial.context?.policyRule } == true
            && editor.lastResolved?.stages.first { $0.id == denial.context?.stageId }?.gitPolicy?.allowed.contains { $0.rule == denial.context?.policyRule } == true
    }
    public var canSave: Bool {
        guard session.detailReadState == .loaded, session.selectedID == taskID, let current = session.detail?.gitDenials.first(where: { $0.denial.denialId == denial.denial.denialId }),
              current.context?.stageId != nil, current.context?.restriction == nil, error == nil, ruleAllowed,
              editor.canApply, let draft = editor.draft else { return false }
        return session.can(.addDenialToPolicy(denialId: denial.denial.denialId, scope: scope, draft: draft))
    }
    public var acceptedVersion: String? {
        guard editor.isApplied, let submitted = editor.submission,
              case .pipelineVersion(let hash) = editor.receipt?.reply?.result,
              hash != submitted.draft.baseVersionHash, editor.source?.baseVersionHash == hash,
              editor.source?.committedContent.map({ Data($0.utf8) }) == Data(submitted.draft.content.utf8) else { return nil }
        return hash
    }
    public func load() async {
        await editor.loadIfNeeded()
        guard baseline == nil, let source = editor.source else { return }
        guard !source.hasWorkingChanges else {
            error = "В .kaban/ есть несохранённые изменения. Завершите их в редакторе pipeline и откройте правило снова."; return
        }
        baseline = source.workingContent
        await choose(scope)
    }
    public func choose(_ scope: PolicyScope) async {
        guard !editor.isPending, !editor.isApplied, let baseline, let context = denial.context else { return }
        self.scope = scope; error = nil
        editor.edit(baseline, debounce: false)
        let prefix: String
        switch scope {
        case .project: prefix = "git"
        case .stage(let id):
            guard id == context.stageId, let stage = editor.document.stages.first(where: { $0.id == id.rawValue }) else {
                error = "Стадия отказа отсутствует в текущем pipeline."; return
            }
            prefix = "stages[\(stage.index)].git"
        }
        let allowPath = prefix + (scope == .project ? ".allow" : ".extend")
        guard editor.document.canEdit(allowPath), editor.document.canEdit(prefix + ".deny") else {
            error = "Этот YAML нельзя безопасно изменить формой. Откройте точный исходный текст в редакторе pipeline."; return
        }
        editor.setGitRule(context.policyRule, allowPath: allowPath, denyPath: prefix + ".deny", decision: .allow)
        await editor.validate()
    }
    public func save() async {
        guard canSave else { return }
        await editor.applyGitDenial(denial.denial.denialId, scope: scope)
        if editor.isApplied { await editor.confirmApplied() }
    }
}
