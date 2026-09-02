import Foundation

/// Translates reference coordinates into consensus coordinates.
///
/// The consensus is not the same length as the reference: applying indels
/// changes it. In the reference dataset the consensus is 29,900 bases against a
/// 29,903 base reference. Laying one over the other by index would drift after
/// the first indel and mis-place every downstream feature, so every position is
/// translated through the indels the variant caller applied.
public struct ConsensusCoordinateMap: Sendable, Equatable {
    public struct Indel: Sendable, Equatable {
        public let position: Int
        public let referenceLength: Int
        public let alternateLength: Int

        public init(position: Int, referenceLength: Int, alternateLength: Int) {
            self.position = position
            self.referenceLength = referenceLength
            self.alternateLength = alternateLength
        }

        /// Bases gained (positive) or lost (negative) at this site.
        var lengthDelta: Int { alternateLength - referenceLength }

        /// Reference positions consumed but not represented in the consensus.
        /// For `AATT` to `A` at p, the anchor base p survives and p+1 through
        /// p+3 are deleted.
        var deletedReferenceRange: ClosedRange<Int>? {
            guard lengthDelta < 0 else { return nil }
            return (position + alternateLength)...(position + referenceLength - 1)
        }
    }

    private let indels: [Indel]

    public init(indels: [Indel]) {
        self.indels = indels.sorted { $0.position < $1.position }
    }

    /// The consensus position for a reference position, or nil when the base
    /// was deleted and therefore has no consensus counterpart.
    public func consensusPosition(forReference position: Int) -> Int? {
        var shift = 0
        for indel in indels {
            if let deleted = indel.deletedReferenceRange, deleted.contains(position) {
                return nil
            }
            if indel.position < position {
                shift += indel.lengthDelta
            }
        }
        return position + shift
    }
}
