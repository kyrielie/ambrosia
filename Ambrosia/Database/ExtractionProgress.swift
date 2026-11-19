import Foundation
import Observation

@Observable
final class ExtractionProgress {
    var completed: Int = 0
    var total: Int = 0
    var isRunning: Bool = false

    var statusText: String? {
        guard isRunning else { return nil }
        return total > 0 ? "Enriching library \(completed)/\(total)" : "Enriching library…"
    }
}

/// When the extraction loop flushes buffered results to the meta DB. Pure so it
/// can be tested without a library. A quit discards at most `batchSize` books or
/// `flushInterval` seconds of finished work; unflushed books are re-attempted on
/// the next launch because the pending set is recomputed from the DB.
enum ExtractionBatchPolicy {
    static let batchSize = 50
    static let flushInterval: TimeInterval = 5

    static func shouldFlush(completedCount: Int, secondsSinceLastFlush: TimeInterval,
                            batchSize: Int = ExtractionBatchPolicy.batchSize,
                            flushInterval: TimeInterval = ExtractionBatchPolicy.flushInterval) -> Bool {
        completedCount > 0
            && (completedCount.isMultiple(of: batchSize) || secondsSinceLastFlush >= flushInterval)
    }
}
