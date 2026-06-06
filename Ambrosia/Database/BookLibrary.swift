import Foundation
import SwiftData

/// Thin wrapper used by Phase 6 (Collections) to query app-owned state.
/// Does NOT reference the removed Book @Model.
class BookLibrary {
    let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Total number of BookState records (one per ever-opened book).
    func totalStateCount() throws -> Int {
        try modelContext.fetch(FetchDescriptor<BookState>()).count
    }

    /// Fetch or create BookState for a given Calibre book ID.
    func state(for calibreID: Int) throws -> BookState {
        var desc = FetchDescriptor<BookState>(
            predicate: #Predicate { $0.calibreID == calibreID }
        )
        desc.fetchLimit = 1
        if let existing = try modelContext.fetch(desc).first {
            return existing
        }
        let state = BookState(calibreID: calibreID)
        modelContext.insert(state)
        return state
    }
}
