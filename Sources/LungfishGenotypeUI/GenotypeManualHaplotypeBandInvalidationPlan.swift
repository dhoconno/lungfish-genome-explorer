import AppKit
import LungfishCore
import LungfishIO

/// The exact visible damage caused by a manual-assignment snapshot change.
///
/// Keeping this calculation value-semantic lets the matrix invalidate only
/// affected, on-screen sample columns without coupling assignment edits to
/// projection or table reload work.
struct GenotypeManualHaplotypeBandInvalidationPlan: Equatable {
    let rects: [NSRect]

    init(
        samples: Set<String>,
        columnFrames: [String: NSRect],
        visibleBounds: NSRect
    ) {
        rects = samples.compactMap { sample in
            guard let frame = columnFrames[sample],
                  frame.intersects(visibleBounds) else {
                return nil
            }
            return frame.intersection(visibleBounds)
        }.sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.width != $1.width { return $0.width < $1.width }
            return $0.height < $1.height
        }
    }
}
