import Foundation
import SwiftData

/// Thin query wrapper — used by FilterBuilder in Phase 2.
/// Phase 1 stub: no logic yet beyond holding a context reference.
class BookLibrary {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Diagnostic: return total book count.
    func totalCount() throws -> Int {
        try modelContext.fetch(FetchDescriptor<Book>()).count
    }
}
