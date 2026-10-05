import Foundation
import GRDB
import KabanProtocol

extension KabanStore {
    /// The cursor, retention check and bounded payload are read in one transaction.
    public func journalPage(after fromSeq: Seq, limit: Int = DaemonWire.maxPageSize) throws -> JournalPage {
        guard fromSeq >= 0, (1...DaemonWire.maxPageSize).contains(limit) else {
            throw CommandError(code: "invalid_request", message: "Некорректный курсор или размер пакета журнала.")
        }
        return try database.read { db in
            let latest = try Self.seq(db)
            let events = try Data.fetchAll(db, sql: "SELECT payload FROM event WHERE seq > ? ORDER BY seq LIMIT ?", arguments: [fromSeq, limit])
                .map { try Self.decode(EventEnvelope.self, $0) }
            var cursor = fromSeq
            var gap = fromSeq > latest
            for event in events {
                guard cursor < Seq.max, event.seq == cursor + 1 else { gap = true; break }
                cursor = event.seq
            }
            if events.count < limit && cursor < latest { gap = true }
            return JournalPage(fromSeq: fromSeq, latestSeq: latest, events: gap ? [] : events, resyncRequired: gap)
        }
    }
}
