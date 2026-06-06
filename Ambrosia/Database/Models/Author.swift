import SwiftData
import Foundation

// Phase 0 stub — relationships deferred to Phase 1
@Model
final class Author {
    var name: String = ""

    init(name: String) {
        self.name = name
    }
}
