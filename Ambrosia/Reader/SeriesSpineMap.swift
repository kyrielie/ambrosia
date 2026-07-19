import Foundation

// MARK: - SeriesSpineMap
//
// Flattens the per-work spine counts of a ReadingTarget into one global,
// series-wide spine ordering. A `.singleBook` target produces a map with
// exactly one work. Rebuilt once per loadEPUB() call; never mutated after
// (see ReaderViewController.spineMap / ambrosia_series_fix_plan.md Task 2a).
//
// "Global index" == position in the flattened series-wide spine.
// "Local index" == position within a single work's own spine.

struct SeriesSpineMap {

    /// Resolves a global spine index to the work and local spine index it
    /// falls within.
    struct GlobalSpineRef {
        let workIndex: Int
        let localIndex: Int
    }

    let workIDs: [Int]
    private let spineCounts: [Int]
    private let workStartOffsets: [Int]

    /// Total number of spine items across all works.
    let count: Int

    init(workIDs: [Int], spineCounts: [Int]) {
        self.workIDs = workIDs
        self.spineCounts = spineCounts

        var starts: [Int] = []
        starts.reserveCapacity(spineCounts.count)
        var running = 0
        for spineCount in spineCounts {
            starts.append(running)
            running += spineCount
        }
        self.workStartOffsets = starts
        self.count = running
    }

    /// Resolves a global spine index to its owning work + local spine index.
    /// Returns nil if out of bounds.
    func ref(atGlobalIndex globalIndex: Int) -> GlobalSpineRef? {
        guard globalIndex >= 0, globalIndex < count else { return nil }
        for workIndex in stride(from: workStartOffsets.count - 1, through: 0, by: -1)
        where globalIndex >= workStartOffsets[workIndex] {
            return GlobalSpineRef(workIndex: workIndex, localIndex: globalIndex - workStartOffsets[workIndex])
        }
        return nil
    }

    /// The Calibre book ID owning the spine item at `globalIndex`.
    func workID(atGlobalIndex globalIndex: Int) -> Int? {
        guard let ref = ref(atGlobalIndex: globalIndex), workIDs.indices.contains(ref.workIndex) else {
            return nil
        }
        return workIDs[ref.workIndex]
    }

    /// The global index corresponding to a (workIndex, localIndex) pair.
    /// Returns nil if either index is out of bounds.
    func globalIndex(workIndex: Int, localIndex: Int) -> Int? {
        guard workStartOffsets.indices.contains(workIndex),
              spineCounts.indices.contains(workIndex),
              localIndex >= 0, localIndex < spineCounts[workIndex] else {
            return nil
        }
        return workStartOffsets[workIndex] + localIndex
    }

    /// True if the spine item at `globalIndex` is the last spine item of its work
    /// (i.e. advancing past it crosses into the next work, or the end of the series).
    func isLastItemInWork(_ globalIndex: Int) -> Bool {
        guard let ref = ref(atGlobalIndex: globalIndex), spineCounts.indices.contains(ref.workIndex) else {
            return false
        }
        return ref.localIndex == spineCounts[ref.workIndex] - 1
    }

    /// True if the spine item at `globalIndex` is the first spine item of its work
    /// (i.e. going back past it crosses into the previous work, or the start of the series).
    func isFirstItemInWork(_ globalIndex: Int) -> Bool {
        guard let ref = ref(atGlobalIndex: globalIndex) else { return false }
        return ref.localIndex == 0
    }

    /// Total number of spine items in the given work (not the series-wide
    /// `count`). Used by paginated mode's whole-book progress estimate,
    /// which has no per-character weighting available (each spine loads in
    /// isolation — see ReaderViewController.savePaginatedProgress) and so
    /// approximates position as (localIndex + fraction) / spineCount.
    func spineCount(forWorkIndex workIndex: Int) -> Int? {
        guard spineCounts.indices.contains(workIndex) else { return nil }
        return spineCounts[workIndex]
    }
}
