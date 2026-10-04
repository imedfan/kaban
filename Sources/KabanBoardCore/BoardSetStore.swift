import Foundation
import KabanProtocol

public enum BoardSetStorageKey {
    /// Набор доски: объект `{lanes, addedOrder}` либо старый JSON-массив id.
    /// Ключа нет — набор ещё не сохраняли.
    public static let lanes = "kaban.boardSet.lanes"
    /// Все проекты, которые набор уже видел. Скрытый проект остаётся здесь, новый — нет.
    public static let known = "kaban.boardSet.known"
}

/// Какие проекты на доске и в каком порядке. Демону это не нужно (арх. §5, §11).
public final class BoardSetStore: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: any KeyValueStoring
    private var board: BoardSet
    private var knownIDs: Set<ProjectID>
    /// `true`, если при `bootstrap` в хранилище уже лежал набор.
    public private(set) var restoredFromSavedSet: Bool

    public init(storage: any KeyValueStoring) {
        self.storage = storage
        self.board = BoardSet()
        self.knownIDs = []
        self.restoredFromSavedSet = false
    }

    public var visibleProjectIds: [ProjectID] {
        lock.lock()
        defer { lock.unlock() }
        return board.lanes
    }

    /// Порядок добавления на доску, не текущий порядок дорожек.
    public var addedOrder: [ProjectID] {
        lock.lock()
        defer { lock.unlock() }
        return board.addedOrder
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
            board = BoardSet(lanes: existing)
            knownIDs = existingSet
            restoredFromSavedSet = false
            persistLocked()
            return
        }
        restoredFromSavedSet = true
        board = loadBoard() ?? BoardSet()
        board.prune(existing: existing)
        knownIDs = Set(loadIDs(BoardSetStorageKey.known) ?? board.lanes)
        for id in existing where !knownIDs.contains(id) {
            board.add(id)
        }
        knownIDs = existingSet
        persistLocked()
    }

    /// Крестик дорожки. Проект только скрывается: из демона его не удаляют и не ставят на паузу.
    /// С порядка добавления он тоже уходит: на доске его больше нет.
    public func hide(_ id: ProjectID) {
        lock.lock()
        defer { lock.unlock() }
        board.remove(id)
        knownIDs.insert(id)
        persistLocked()
    }

    /// «Показать на доске». Уже видимый проект только переезжает.
    /// Скрытый возвращается в конец порядка добавления.
    public func show(_ id: ProjectID, at index: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        board.add(id, at: index)
        knownIDs.insert(id)
        persistLocked()
    }

    public func moveLeft(_ id: ProjectID) { shift(id, by: -1) }
    public func moveRight(_ id: ProjectID) { shift(id, by: 1) }

    public func move(_ id: ProjectID, to index: Int) {
        lock.lock()
        defer { lock.unlock() }
        board.move(id, to: index)
        persistLocked()
    }

    /// Новый проект (`projectAdded`) появляется на доске последней дорожкой.
    public func noteProjectAdded(_ id: ProjectID) {
        lock.lock()
        defer { lock.unlock() }
        knownIDs.insert(id)
        if !board.lanes.contains(id) {
            board.add(id)
        }
        persistLocked()
    }

    public func noteProjectRemoved(_ id: ProjectID) {
        lock.lock()
        defer { lock.unlock() }
        board.remove(id)
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
        guard (1...9).contains(shortcut), shortcut <= board.lanes.count else { return nil }
        return shortcut - 1
    }

    private func shift(_ id: ProjectID, by delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        board.shiftDisplay(id, by: delta)
        persistLocked()
    }

    private func persistLocked() {
        storage.set(encode(board), forKey: BoardSetStorageKey.lanes)
        storage.set(encode(Array(knownIDs).sorted { $0.rawValue < $1.rawValue }), forKey: BoardSetStorageKey.known)
    }

    private func loadBoard() -> BoardSet? {
        guard let data = storage.data(forKey: BoardSetStorageKey.lanes) else { return nil }
        return try? JSONDecoder().decode(BoardSet.self, from: data)
    }

    private func loadIDs(_ key: String) -> [ProjectID]? {
        guard let data = storage.data(forKey: key) else { return nil }
        return (try? JSONDecoder().decode([ProjectID].self, from: data)) ?? []
    }

    private func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private func unique(_ ids: [ProjectID]) -> [ProjectID] {
        var seen = Set<ProjectID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
