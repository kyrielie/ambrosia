import SwiftData
import Foundation

// Phase 0 stub — Book relationship deferred to Phase 1
@Model
final class ReadingState {
    var spineIndex: Int = 0
    var characterOffset: Int = 0
    var lastUpdated: Date = Date()

    init() {}
}
