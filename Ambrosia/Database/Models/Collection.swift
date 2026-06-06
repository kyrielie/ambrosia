import SwiftData
import Foundation

@Model
final class Collection {
    var name: String
    var createdDate: Date = Date()

    // NOTE: No @Relationship attribute here — inverse: is declared on Book.collections only.
    // This is intentional per project plan invariant: declaring inverse: on both sides
    // causes a circular macro resolution compile error in SwiftData.
    // SwiftData resolves the relationship from Book's @Relationship(inverse: \Collection.books).
    var books: [Book] = []

    init(name: String) {
        self.name = name
    }
}
