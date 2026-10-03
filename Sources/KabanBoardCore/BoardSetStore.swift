import Foundation
import KabanProtocol

public enum BoardSetStorageKey {
    /// Упорядоченные id проектов, которые сейчас на доске. Ключа нет — набор ещё не сохраняли.
    public static let lanes = "kaban.boardSet.lanes"
    /// Все проекты, которые набор уже видел. Скрытый проект остаётся здесь, новый — нет.
    public static let known = "kaban.boardSet.known"
}

/// Какие проекты на доске и в каком порядке. Демону это не нужно (арх. §5, §11).
public final class BoardSetStore: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: any KeyValueStoring
    private var laneIDs: [ProjectID]
    private var knownIDs: Set<ProjectID>
    /// `true`, если при `bootstrap` в хранилище уже лежал набор.
    public private(set) var restoredFromSavedSet: Bool

    public init(storage: any KeyValueStoring) {
        self.storage = storage
        self.laneIDs = []
        self.knownIDs = []
        self.restoredFromSavedSet = false
    }

    public var visibleProjectIds: [ProjectID] {
        lock.lock()
        defer { lock.unlock() }
        return laneIDs
    }

    /// Первый запуск без сохранённого набора показывает все проекты.
    /// Уже сохранённый набор чистится от пропавших id; проект, которого набор ещё не видел, встаёт в конец.
    /// Скрытые (их нет в дорожках, но они есть в `known`) сами не возвращаются.
    public func bootstrap(projects: [ProjectID]) {
        lock.lock()
        defer { lock.unlock() }
        let existing = unique(projects)
        let existingSet = Set(existing)
        if storage.data(forKey: BoardSetStorageKey.lanes) == nil {
            laneIDs = existing
            knownIDs = existingSet
            restoredFromSavedSet = false
            persistLocked()
            return
        }
        restoredFromSavedSet = true
        laneIDs = loadIDs(BoardSetStorageKey.lanes) ?? []
        knownIDs = Set(loadIDs(BoardSetStorageKey.known) ?? laneIDs)
        laneIDs.removeAll { !existingSet.contains($0) }
        for id in existing where !knownIDs.contains(id) {
            laneIDs.append(id)
        }
        knownIDs = existingSet
        persistLocked()
    }

    /// Крестик дорожки. Проект только скрывается: из демона его не удаляют и не ставят на паузу.
    public func hide(_ id: ProjectID) {
        lock.lock()
        defer { lock.unlock() }
        laneIDs.removeAll { $0 == id }
        knownIDs.insert(id)
        persistLocked()
    }

    /// «Показать на доске». Повтор не дублирует: уже видимый проект переезжает на `index`.
    public func show(_ id: ProjectID, at index: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        laneIDs.removeAll { $0 == id }
        let destination = index ?? laneIDs.count
        let clamped = min(max(0, destination), laneIDs.count)
        laneIDs.insert(id, at: clamped)
        knownIDs.insert(id)
        persistLocked()
    }

    public func moveLeft(_ id: ProjectID) { shift(id, by: -1) }
    public func moveRight(_ id: ProjectID) { shift(id, by: 1) }

    public func move(_ id: ProjectID, to index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = laneIDs.firstIndex(of: id) else { return }
        laneIDs.remove(at: current)
        let clamped = min(max(0, index), laneIDs.count)
        laneIDs.insert(id, at: clamped)
        persistLocked()
    }

    /// Новый проект (`projectAdded`) появляется на доске последней дорожкой.
    public func noteProjectAdded(_ id: ProjectID) {
        lock.lock()
        defer { lock.unlock() }
        knownIDs.insert(id)
        if !laneIDs.contains(id) {
            laneIDs.append(id)
        }
        persistLocked()
    }

    public func noteProjectRemoved(_ id: ProjectID) {
        lock.lock()
        defer { lock.unlock() }
        laneIDs.removeAll { $0 == id }
        knownIDs.remove(id)
        persistLocked()
    }

    public func apply(_ event: JournalEvent) {
        switch event {
        case .projectAdded(let project): noteProjectAdded(project.id)
        case .projectRemoved(let id): noteProjectRemoved(id)
        default: break
        }
    }

    /// Индекс дорожки для ⌘1…⌘9, с нуля. `nil`, если такой дорожки нет.
    public func focusIndex(forShortcut shortcut: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard (1...9).contains(shortcut), shortcut <= laneIDs.count else { return nil }
        return shortcut - 1
    }

    private func shift(_ id: ProjectID, by delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = laneIDs.firstIndex(of: id) else { return }
        let destination = current + delta
        guard laneIDs.indices.contains(destination) else { return }
        laneIDs.swapAt(current, destination)
        persistLocked()
    }

    private func persistLocked() {
        storage.set(encode(laneIDs), forKey: BoardSetStorageKey.lanes)
        storage.set(encode(Array(knownIDs).sorted { $0.rawValue < $1.rawValue }), forKey: BoardSetStorageKey.known)
    }

    private func loadIDs(_ key: String) -> [ProjectID]? {
        guard let data = storage.data(forKey: key) else { return nil }
        return (try? JSONDecoder().decode([ProjectID].self, from: data)) ?? []
    }

    private func encode(_ ids: [ProjectID]) -> Data? {
        try? JSONEncoder().encode(ids)
    }

    private func unique(_ ids: [ProjectID]) -> [ProjectID] {
        var seen = Set<ProjectID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
