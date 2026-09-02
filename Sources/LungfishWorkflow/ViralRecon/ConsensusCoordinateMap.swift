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

    /// Extracts length-changing variants from VCF body lines.
    ///
    /// Substitutions leave the coordinate system alone and are ignored. Only
    /// indels shift downstream positions.
    public static func indels(fromVCFLines lines: [String]) -> [Indel] {
        var result: [Indel] = []
        for line in lines {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let position = Int(fields[1]) else { continue }
            let reference = String(fields[3])
            guard let firstAlternate = fields[4].split(separator: ",").first else { continue }
            let alternate = String(firstAlternate)
            guard reference.count != alternate.count else { continue }
            result.append(Indel(position: position,
                                referenceLength: reference.count,
                                alternateLength: alternate.count))
        }
        return result
    }
}
