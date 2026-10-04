import Foundation
import KabanProtocol

/// Чистый набор доски: порядок дорожек и отдельно порядок добавления.
/// Коллизии маскотов смотрят `addedOrder`, перетаскивание меняет только дорожки.
public struct BoardSet: Equatable, Sendable {
    /// Текущий порядок видимых дорожек.
    public private(set) var lanes: [ProjectID]
    /// Порядок, в котором проекты попали на доску. Перестановка дорожек его не меняет.
    public private(set) var addedOrder: [ProjectID]

    public init(lanes: [ProjectID] = [], addedOrder: [ProjectID]? = nil) {
        self.lanes = Self.unique(lanes)
        self.addedOrder = Self.unique(addedOrder ?? self.lanes)
    }

    /// Ставит проект на доску. В `addedOrder` попадает только новый id:
    /// повторное добавление уже известного id этот порядок не меняет.
    public mutating func add(_ id: ProjectID, at index: Int? = nil) {
        if !addedOrder.contains(id) {
            addedOrder.append(id)
        }
        lanes.removeAll { $0 == id }
        let destination = index ?? lanes.count
        let clamped = min(max(0, destination), lanes.count)
        lanes.insert(id, at: clamped)
    }

    /// Меняет только порядок дорожек.
    public mutating func move(_ id: ProjectID, to index: Int) {
        guard let current = lanes.firstIndex(of: id) else { return }
        lanes.remove(at: current)
        let clamped = min(max(0, index), lanes.count)
        lanes.insert(id, at: clamped)
    }

    /// Сдвигает дорожку, не трогая порядок добавления. Край — пустая операция.
    public mutating func shiftDisplay(_ id: ProjectID, by delta: Int) {
        guard let current = lanes.firstIndex(of: id) else { return }
        let destination = current + delta
        guard lanes.indices.contains(destination) else { return }
        lanes.swapAt(current, destination)
    }

    /// Снимает проект и с дорожек, и с порядка добавления.
    /// Повторный `add` после этого ставит его в конец `addedOrder`.
    public mutating func remove(_ id: ProjectID) {
        lanes.removeAll { $0 == id }
        addedOrder.removeAll { $0 == id }
    }

    /// Выкидывает id, которых больше нет среди проектов.
    public mutating func prune(existing: some Sequence<ProjectID>) {
        let keep = Set(existing)
        lanes.removeAll { !keep.contains($0) }
        addedOrder.removeAll { !keep.contains($0) }
    }

    private static func unique(_ ids: [ProjectID]) -> [ProjectID] {
        var seen = Set<ProjectID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

extension BoardSet: Codable {
    private enum CodingKeys: String, CodingKey {
        case lanes
        case addedOrder
    }

    /// Старый формат — JSON-массив id (только дорожки) или объект без `addedOrder`.
    /// В обоих случаях порядок добавления равен текущему порядку дорожек.
    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), keyed.contains(.lanes) {
            let lanes = try keyed.decode([ProjectID].self, forKey: .lanes)
            self.lanes = Self.unique(lanes)
            let added = try keyed.decodeIfPresent([ProjectID].self, forKey: .addedOrder) ?? lanes
            self.addedOrder = Self.unique(added)
            return
        }
        let ids = try decoder.singleValueContainer().decode([ProjectID].self)
        self.lanes = Self.unique(ids)
        self.addedOrder = self.lanes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lanes, forKey: .lanes)
        try container.encode(addedOrder, forKey: .addedOrder)
    }
}
