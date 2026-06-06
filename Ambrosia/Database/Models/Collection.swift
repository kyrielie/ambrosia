import SwiftData
import Foundation

/// A user-created collection of books, identified by their Calibre IDs.
///
/// STORAGE INVARIANT: Book membership is stored as a comma-separated String of
/// integer Calibre IDs (e.g. "42,107,1337"). We never store [Int] or [Book]
/// on a @Model — bare Swift collections cause a silent CoreData fault at runtime.
@Model
final class Collection {
    var name: String
    var createdDate: Date = Date()

    /// Comma-separated Calibre book IDs. Use the computed `calibreIDs` accessor.
    var calibreIDsRaw: String = ""

    var calibreIDs: [Int] {
        get {
            guard !calibreIDsRaw.isEmpty else { return [] }
            return calibreIDsRaw
                .components(separatedBy: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        set {
            calibreIDsRaw = newValue.map(String.init).joined(separator: ",")
        }
    }

    func contains(calibreID: Int) -> Bool { calibreIDs.contains(calibreID) }

    func add(calibreID: Int) {
        var ids = calibreIDs
        if !ids.contains(calibreID) { ids.append(calibreID) }
        calibreIDs = ids
    }

    func remove(calibreID: Int) {
        calibreIDs = calibreIDs.filter { $0 != calibreID }
    }

    init(name: String) { self.name = name }
}
