import Foundation

enum ReadViewportPolicy {
    static let coverageThresholdBpPerPx: Double = 2.0
    static let baseThresholdBpPerPx: Double = 0.6

    static func zoomTier(scale: Double) -> ReadTrackRenderer.ZoomTier {
        if scale > coverageThresholdBpPerPx {
            return .coverage
        } else if scale > baseThresholdBpPerPx {
            return .packed
        } else {
            return .base
        }
    }

    static func allowsIndividualReads(scale: Double) -> Bool {
        zoomTier(scale: scale) != .coverage
    }

    // MARK: - Displayed-depth cap

    /// Default maximum displayed read depth for one fetch window.
    ///
    /// Regions deeper than this are subsampled to about this depth, per ~1 kb
    /// bin, and every other region shows every read (owner decision D9). A
    /// fixed read-count budget used to thin the whole window uniformly, which
    /// hollowed a 50x flank to under 4x beside a 5,000x amplicon. Depth,
    /// coverage and consensus come from separate queries and are unaffected.
    static let defaultMaxDisplayedDepth = 500

    /// Range and step of the Inspector's "Maximum displayed depth" control.
    static let maxDisplayedDepthRange: ClosedRange<Int> = 50...5_000
    static let maxDisplayedDepthStep = 50

    /// Clamps a requested cap into range and snaps it to the step.
    static func clampMaxDisplayedDepth(_ value: Int) -> Int {
        let range = maxDisplayedDepthRange
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        let steps = Int((Double(clamped - range.lowerBound) / Double(maxDisplayedDepthStep)).rounded())
        return min(range.upperBound, range.lowerBound + steps * maxDisplayedDepthStep)
    }

    /// Absolute ceiling for a "Load all" request, so the escape hatch cannot
    /// stream an unbounded SAM payload into the process.
    static let loadAllReadCeiling = 2_000_000
}
