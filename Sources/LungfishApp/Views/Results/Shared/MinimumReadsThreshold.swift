import Foundation

/// A shared low-abundance read-count threshold used by result viewports that
/// suppress or flag samples below a minimum number of reads.
///
/// Two distinct viewport concerns intentionally reuse this single value type
/// WITHOUT collapsing into one overloaded field:
/// - 12S (`TwelveSResultDisplayState.minimumExactReads`) treats it as a live
///   row-visibility filter (default off, i.e. `value == 0`).
/// - MHC genotype (`GenotypeResultDisplayState`) keeps a separate editable
///   row filter (`minimumReads`) AND a separate "calls below this are
///   unreliable" cohort flag (`cohortFlagThreshold`); each maps to its own
///   `MinimumReadsThreshold` so the filter and the flag never alias.
struct MinimumReadsThreshold: Equatable, Sendable {
    var value: Int
    var isEnabled: Bool

    init(value: Int = 0, isEnabled: Bool = true) {
        self.value = max(0, value)
        self.isEnabled = isEnabled
    }

    /// The effective threshold: `0` when disabled (no suppression), otherwise
    /// the clamped non-negative `value`.
    var active: Int {
        isEnabled ? max(0, value) : 0
    }

    /// Whether a sample with `reads` reads clears the active threshold.
    func includes(reads: Int) -> Bool {
        reads >= active
    }
}
