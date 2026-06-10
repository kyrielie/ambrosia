import Foundation
import Observation

@Observable
final class ExtractionProgress {
    var completed: Int = 0
    var total: Int = 0
    var isRunning: Bool = false

    var statusText: String? {
        guard isRunning else { return nil }
        return total > 0 ? "Enriching library \(completed)/\(total)" : "Enriching library..."
    }
}
