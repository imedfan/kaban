import Foundation
import GRDB
import KabanKit
import KabanProtocol

extension KabanStore {
    struct SuspiciousObservation {
        let task: DurableTask
        let files: [SuspiciousFile]
    }

    func prepareSuspiciousAcceptance(_ command: Command) throws -> Result<SuspiciousObservation, CommandError>? {
        guard case .acceptSuspiciousFiles(let id, _) = command else { return nil }
        let task: DurableTask
        do { task = try database.read { try Self.task(id, db: $0) } }
        catch StoreError.taskMissing { return nil }
        guard task.machine.state == .waitingHuman(.suspiciousFiles),
              try database.read({ try Self.project(task.card.projectId, db: $0).production != nil }) else { return nil }
        guard let clone = try readyClone(id) else {
            return .failure(.init(code: "clone_unavailable", message: "Клон недоступен. Файлы не приняты; восстановите клон и повторите проверку."))
        }
        let identity = try projectIdentity(task)
        do { return .success(.init(task: task, files: try currentSuspiciousFiles(task: task, clone: clone, identity: identity))) }
        catch {
            return .failure(.init(code: "suspicious_files_unreadable", message: "Не удалось перепроверить diff ветки. Файлы не приняты."))
        }
    }

    func currentSuspiciousFiles(task: DurableTask, clone: ReadyClone, identity: GitIdentity?) throws -> [SuspiciousFile] {
        let files = try TaskClone.collectBranchFiles(clone: clone.clonePath, base: clone.baseCommit ?? "",
                                                   strict: task.pipeline.git.preset == .strict, identity: identity)
        let accepted = try database.read { db in Set(try Self.acceptedFileRows(task.card.id, db: db).map { FileBlobRef(path: $0.path, blob: $0.blob) }) }
        var found = SuspiciousFilesScanner.scan(files.map(\.file), policy: task.pipeline.suspiciousFiles, accepted: accepted)
        let text = Dictionary(files.map { ($0.file.path, $0.isText) }, uniquingKeysWith: { _, last in last })
        for index in found.indices { found[index].isText = text[found[index].path] ?? false }
        return found
    }

    static func refreshSuspiciousAcceptance(_ observation: SuspiciousObservation, shown: [FileBlobRef], at: Date, db: Database) throws -> CommandError? {
        var task = try Self.task(observation.task.card.id, db: db)
        guard task == observation.task else {
            return .init(code: CommandError.staleSuspiciousFilesCode, message: "Состояние задачи изменилось. Обновите детали; ничего не принято.")
        }
        if task.machine.suspiciousFiles != observation.files {
            task.machine.suspiciousFiles = observation.files
            task.machine.apply(to: &task.card, stage: task.pipeline.stage(task.machine.stageId))
            task.card.updatedAt = at
            try db.execute(sql: "UPDATE task SET payload = ? WHERE id = ?", arguments: [try encode(task), task.card.id.rawValue])
            // A fresh observation must not confirm the refused human command.
            let observationID = UUID()
            try recordSafetyEffects(command: .resultSuspicious(observation.files),
                                    effects: [.reportSuspiciousFiles(observation.files, runId: nil)],
                                    task: task, commandId: observationID, at: at, db: db)
            _ = try journal(.taskUpdated(task.card), task: task, commandId: observationID, at: at, db: db)
        }
        guard SuspiciousFilesScanner.sameSet(observation.files, shown) else {
            return .init(code: CommandError.staleSuspiciousFilesCode, message: "Набор файлов изменился — ничего не принято. Просмотрите обновлённый набор и подтвердите его снова.")
        }
        return nil
    }
}
