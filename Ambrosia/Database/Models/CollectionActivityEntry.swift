import Foundation

/// A single collection-membership event for display in the activity feed.
/// Value type — never persisted; reconstructed from `collection_members` on each load.
struct CollectionActivityEntry: Identifiable, Sendable {
    /// Stable string key: "\(collectionID)-\(calibreID)"
    let id: String
    let collectionID: String
    let collectionName: String
    /// Raw `kind` string from the `collections` table.
    let kind: String
    let calibreID: Int
    let addedAt: Date
    let isSystem: Bool
}
