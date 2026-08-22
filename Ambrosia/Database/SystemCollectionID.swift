enum SystemCollectionID {
    static let seriesOrMergedName = "Series or Merged"

    static let readLater = "00000000-0000-0000-0000-000000000001"
    static let liked = "00000000-0000-0000-0000-000000000002"
    static let skipped = "00000000-0000-0000-0000-000000000003"
    static let finished = "00000000-0000-0000-0000-000000000004"
    static let inProgress = "00000000-0000-0000-0000-000000000005"
    static let hasAnnotations = "00000000-0000-0000-0000-000000000006"
    static let seriesOrMerged = "00000000-0000-0000-0000-000000000007"

    static let bootstrapRows: [(id: String, name: String, kind: String, sortOrder: Int)] = [
        (readLater, "Read Later", "readLater", 0),
        (liked, "Liked", "liked", 1),
        (skipped, "Skipped", "hidden", 2),
        (finished, "Finished", "automated", 3),
        (inProgress, "In Progress", "automated", 4),
        (hasAnnotations, "Has Annotations", "automated", 5),
        (seriesOrMerged, seriesOrMergedName, "automated", 6)
    ]
}
