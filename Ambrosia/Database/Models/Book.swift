import SwiftData
import Foundation

// Phase 0 stub — relationships deferred to Phase 1 to avoid circular reference
// compile errors during initial project setup.
@Model
final class Book {
    var title: String = ""
    var filePath: String = ""

    init(title: String, filePath: String) {
        self.title = title
        self.filePath = filePath
    }
}
