import Foundation

/// Pure Swift helper for non-destructive text-edit overlap pre-flight and
/// descending-offset shifting of downstream annotations.
enum TextReplacementOffsetShift {

    struct ShiftedRange: Equatable, Sendable {
        let id: UUID
        let startChar: Int
        let endChar: Int
    }

    /// Returns `true` if `[startChar, endChar)` overlaps any other annotation in the same spine item.
    static func hasOverlap(
        startChar: Int,
        endChar: Int,
        spineIndex: Int,
        annotations: [Annotation],
        excludingID: UUID
    ) -> Bool {
        annotations.contains { other in
            guard other.id != excludingID,
                  other.spineIndex == spineIndex else { return false }
            if other.isPointAnnotation {
                return other.startChar > startChar && other.startChar < endChar
            }
            return startChar < other.endChar && endChar > other.startChar
        }
    }

    /// Computes shifted ranges for all annotations strictly downstream of `editEnd`
    /// in the same spine item, sorted in descending `startChar` order so database
    /// updates never collide.
    static func downstreamShifts(
        editEnd: Int,
        delta: Int,
        spineIndex: Int,
        annotations: [Annotation],
        excludingID: UUID
    ) -> [ShiftedRange] {
        guard delta != 0 else { return [] }
        return annotations
            .filter { $0.id != excludingID && $0.spineIndex == spineIndex && $0.startChar >= editEnd }
            .sorted { $0.startChar > $1.startChar }
            .map { ann in
                ShiftedRange(
                    id: ann.id,
                    startChar: max(0, ann.startChar + delta),
                    endChar: max(0, ann.endChar + delta)
                )
            }
    }
}
