import Foundation
import Observation
import KabanProtocol

@MainActor @Observable public final class PipelineEditorStore {
    public enum GitRuleEdit: String, Sendable { case inherit, allow, deny }
    public enum ValidationState: Equatable {
        case idle, checking
        case checked(PipelineDraftValidation)
        case unavailable(String)
    }
    public struct Submission: Equatable {
        public let commandID: CommandID
        public let draft: PipelineDraft
    }
    public let projectID: ProjectID
    public private(set) var source: PipelineSourceContent?
    public private(set) var changedSource: PipelineSourceContent?
    public private(set) var content = ""
    public private(set) var document = PipelineTextDocument("")
    public private(set) var validation: ValidationState = .idle
    public private(set) var lastResolved: PipelineSummary?
    public private(set) var submission: Submission?
    public private(set) var error: String?
    public private(set) var loading = false
    public private(set) var writing = false
    private let client: any KabanClient
    private let session: BoardSession
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var validationGeneration = UUID()
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    public init(projectID: ProjectID, client: any KabanClient, session: BoardSession) {
        self.projectID = projectID; self.client = client; self.session = session
    }
    deinit { checkTask?.cancel() }
    public var draft: PipelineDraft? {
        source.map { .init(projectId: projectID, baseVersionHash: $0.baseVersionHash, content: content, baseSourceHash: $0.baseSourceHash) }
    }
    public var issues: [ValidationIssue] {
        if case .checked(let value) = validation { return value.issues }; return []
    }
    public var receipt: ClientCommandJournal.Record? {
        _ = session.pendingRecords
        return submission.flatMap { submitted in session.journal?.records.first { $0.envelope.commandId == submitted.commandID } }
    }
    public var isPending: Bool { writing || receipt?.isPending == true }
    public var isApplied: Bool { receipt?.phase == .applied }
    public var isCurrentDraftApplied: Bool { isApplied && submission?.draft.contentHash == draft?.contentHash }
    public var hasDraftChanges: Bool { source.map { Data(content.utf8) != Data(($0.workingContent ?? "").utf8) } ?? false }
    public var connectionAvailable: Bool { session.can(.validatePipelineDraft) }
    public var baseChanged: Bool {
        guard let source, let current = session.projection?.pipelines[projectID] else { return false }
        return current.versionHash != source.baseVersionHash || current.sourceHash != source.baseSourceHash
    }
    public var canApply: Bool {
        guard session.can(.updatePipeline(projectId: projectID, contentHash: "")), !isPending, !loading,
              changedSource == nil, !baseChanged, !isCurrentDraftApplied, let draft,
              case .checked(let checked) = validation, checked.projectId == projectID,
              checked.contentHash == draft.contentHash, checked.baseVersionHash == draft.baseVersionHash,
              checked.baseSourceHash == draft.baseSourceHash else { return false }
        return !checked.issues.contains { $0.severity == .error }
    }
    public func edit(_ text: String, debounce: Bool = true) {
        guard !text.utf8.elementsEqual(content.utf8) else { return }
        content = text; document = .init(text); error = nil; validation = .idle
        generation = UUID(); checkTask?.cancel()
        if debounce {
            checkTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                await self?.validate()
            }
        }
    }
    public func patch(_ path: String, value: String, quoted: Bool = false) {
        do { edit(try document.replacing(path, with: value, quoted: quoted)) }
        catch { self.error = error.localizedDescription }
    }
    public func setGitRule(_ rule: String, allowPath: String, denyPath: String, decision: GitRuleEdit) {
        guard !isPending, var allowed = document.stringList(allowPath), var denied = document.stringList(denyPath) else { return }
        allowed.removeAll { $0 == rule }; denied.removeAll { $0 == rule }
        if decision == .allow { allowed.append(rule) }; if decision == .deny { denied.append(rule) }
        do {
            let text = try document.replacing(allowPath, with: "[" + allowed.map(PipelineTextDocument.quote).joined(separator: ", ") + "]")
            edit(try PipelineTextDocument(text).replacing(denyPath, with: "[" + denied.map(PipelineTextDocument.quote).joined(separator: ", ") + "]"))
        } catch { self.error = error.localizedDescription }
    }
    public func addStage(id: String, kind: String) {
        do { edit(try document.addingStage(id: id, kind: kind)) }
        catch { self.error = error.localizedDescription }
    }
    public func activeTaskCount(stage: String) -> Int {
        session.projection?.tasks.values.filter { $0.projectId == projectID && $0.stageId.rawValue == stage && $0.state.status != .done && $0.state.status != .cancelled }.count ?? 0
    }
    public func removeStage(index: Int, id: String) {
        guard activeTaskCount(stage: id) == 0 else { error = "Сначала перенесите задачи из этой стадии."; return }
        do { edit(try document.removingStage(index: index)) }
        catch { self.error = error.localizedDescription }
    }
    public func loadIfNeeded() async { if source == nil { await readSource() } }
    public func readSource(replaceDraft: Bool = false) async {
        guard !loading, !isPending else { return }
        loading = true; defer { loading = false }
        let before = generation
        do {
            let value = try await fetchSource()
            guard before == generation else { return }
            if source == nil || replaceDraft {
                source = value; changedSource = nil; content = value.workingContent ?? ""
                document = .init(content)
                generation = UUID(); submission = nil; error = nil
            } else if let source, value.baseSourceHash == source.baseSourceHash, value.baseVersionHash == source.baseVersionHash,
                      value.workingContent.map({ Data($0.utf8) }) == source.workingContent.map({ Data($0.utf8) }) {
                self.source = value; changedSource = nil; error = nil
            } else {
                changedSource = value; error = "Исходный файл или committed версия изменились. Ваш черновик сохранён. Сравните YAML перед перезагрузкой или выбором новой базы."
            }
            await validate()
        } catch { self.error = message(error); validation = .unavailable(message(error)) }
    }
    public func keepDraftOnChangedSource() async {
        guard let changedSource, !isPending else { return }
        source = changedSource; self.changedSource = nil; error = nil; submission = nil
        generation = UUID(); await validate()
    }
    public func validate() async {
        guard let draft else { return }
        let requestGeneration = UUID(); validationGeneration = requestGeneration
        guard session.can(.validatePipelineDraft) else {
            validation = .unavailable("Проверка недоступна. Подключитесь к службе Kaban с поддержкой редактора."); return
        }
        let token = generation, connection = session.sessionGeneration
        validation = .checking
        let envelope = CommandEnvelope(command: .validatePipelineDraft(draft: draft))
        do {
            let reply = try await client.send(envelope)
            guard validationGeneration == requestGeneration, generation == token, session.sessionGeneration == connection, self.draft == draft else { return }
            guard reply.commandId == envelope.commandId else { throw invalidReply() }
            if case .error(let failure) = reply.result { throw failure }
            guard case .pipelineDraft(let value) = reply.result, value.projectId == projectID,
                  value.contentHash == draft.contentHash, value.baseVersionHash == draft.baseVersionHash,
                  value.baseSourceHash == draft.baseSourceHash else { throw invalidReply() }
            validation = .checked(value)
            if let resolved = value.resolved { lastResolved = resolved }
        } catch {
            guard validationGeneration == requestGeneration, generation == token, session.sessionGeneration == connection else { return }
            validation = .unavailable(message(error))
        }
    }
    public func apply() async {
        guard canApply, let source, var draft else { return }
        writing = true; defer { writing = false }
        let token = generation
        do {
            let fresh = try await fetchSource()
            guard token == generation, self.draft == draft else { return }
            guard fresh == source else {
                changedSource = fresh
                throw CommandError(code: "pipeline_worktree_conflict", message: "Файл или версия .kaban/ изменились. Ваш ввод сохранён; сравните новую версию.")
            }
            guard session.can(.updatePipeline(projectId: projectID, contentHash: draft.contentHash)), !baseChanged else { throw invalidReply() }
            let text = draft.content
            try await Task.detached { try PipelineFileWriter.write(text, source: source) }.value
            draft.requiresExactWorkingContent = true
            let envelope = CommandEnvelope(command: .updatePipeline(projectId: projectID, contentHash: draft.contentHash, draft: draft))
            submission = .init(commandID: envelope.commandId, draft: draft)
            let sent = await session.send(envelope)
            if case .validationIssues(let issues) = receipt?.reply?.result, self.draft?.contentHash == draft.contentHash {
                validation = .checked(.init(projectId: projectID, contentHash: draft.contentHash, issues: issues,
                                           resolved: lastResolved, baseVersionHash: draft.baseVersionHash, baseSourceHash: draft.baseSourceHash))
            }
            if !sent {
                if case .error(let failure) = receipt?.reply?.result { error = failure.message }
                else { error = "Применение не подтверждено. Черновик и файл сохранены; проверьте исход команды." }
            }
            // Never undo our disk write. A later editor owns its new bytes.
        } catch { self.error = message(error) }
    }
    public func confirmApplied() async {
        guard isApplied, let submitted = submission else { return }
        do {
            let fresh = try await fetchSource()
            guard submission == submitted, isApplied else { return }
            source = fresh
            if fresh.workingContent.map({ Data($0.utf8) }) != Data(submitted.draft.content.utf8) {
                changedSource = fresh; error = "Версия применена, но рабочий файл изменён позже. Черновик сохранён."
            } else { changedSource = nil; error = nil }
            generation = UUID(); await validate()
        } catch { self.error = message(error) }
    }
    private func fetchSource() async throws -> PipelineSourceContent {
        guard session.can(.getPipelineSource) else { throw CommandError(code: "unsupported_command", message: "Чтение исходного YAML недоступно у подключённой службы.") }
        let connection = session.sessionGeneration
        let envelope = CommandEnvelope(command: .getPipelineSource(projectId: projectID))
        let reply = try await client.send(envelope)
        guard session.sessionGeneration == connection, reply.commandId == envelope.commandId else { throw invalidReply() }
        if case .error(let failure) = reply.result { throw failure }
        guard case .pipelineSource(let source) = reply.result, source.projectId == projectID,
              let project = session.projection?.projects[projectID],
              source.path == URL(fileURLWithPath: project.path).appendingPathComponent(".kaban/pipeline.yaml").path else { throw invalidReply() }
        return source
    }
    private func invalidReply() -> CommandError { .init(code: "stale_pipeline_read", message: "Ответ относится к прежней сессии или черновику. Повторите проверку; ввод сохранён.") }
    private func message(_ error: any Error) -> String { (error as? CommandError)?.message ?? error.localizedDescription }
}
