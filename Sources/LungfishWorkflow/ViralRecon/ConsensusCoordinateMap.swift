import Foundation

/// Translates reference coordinates into consensus coordinates.
///
/// The consensus is not the same length as the reference: applying indels
/// changes it. In the reference dataset the consensus is 29,900 bases against a
/// 29,903 base reference. Laying one over the other by index would drift after
/// the first indel and mis-place every downstream feature, so every position is
/// translated through the indels the variant caller applied.
///
/// NOT YET WIRED. No consensus track reads this map. It is kept, and kept
/// correct, because the alternative to a correct map is a display that quietly
/// lies about where a feature sits, which is the single most likely way for
/// this work to ship a silent error. Whoever wires the consensus track should
/// build the map from the same VCF `bcftools consensus` was given.
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

        /// Reference positions this record consumes, including its anchor.
        ///
        /// Used to detect records that overlap one already applied. An
        /// insertion consumes only its anchor base, so two insertions at
        /// distinct positions never conflict.
        var consumedReferenceRange: ClosedRange<Int> {
            position...(position + max(referenceLength, 1) - 1)
        }
    }

    /// The indels actually applied, in position order, with any record that
    /// overlapped an earlier one already dropped.
    private let indels: [Indel]

    public init(indels: [Indel]) {
        self.indels = Self.applicable(from: indels)
    }

    /// Drops records that overlap one already applied.
    ///
    /// `bcftools consensus` walks the VCF in coordinate order and skips any
    /// record whose reference span overlaps one it has already written. Two
    /// deletions covering the same bases cannot both happen, and counting both
    /// double-subtracts, dragging every downstream position out of place.
    /// Earlier records win, matching bcftools' own first-come order.
    private static func applicable(from indels: [Indel]) -> [Indel] {
        var applied: [Indel] = []
        var lastConsumedEnd: Int?

        for indel in indels.sorted(by: { $0.position < $1.position }) {
            let consumed = indel.consumedReferenceRange
            if let lastConsumedEnd, consumed.lowerBound <= lastConsumedEnd {
                continue
            }
            applied.append(indel)
            lastConsumedEnd = consumed.upperBound
        }
        return applied
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
    ///
    /// Two records are deliberately excluded:
    ///
    /// - Records that did not pass the filter. `bcftools consensus` applies
    ///   only passing records, so counting a failing one shifts the map against
    ///   a consensus that never moved. `PASS`, `.` and an empty field all count
    ///   as passing; anything else does not.
    /// - Multi-allelic records whose allele cannot be determined. `ALT[0]` is
    ///   not authoritative: bcftools applies the allele the genotype names.
    ///   Guessing the first one shifts every downstream position by the wrong
    ///   amount, so a site with no usable genotype is skipped rather than
    ///   guessed. A single-ALT record is unambiguous and needs no genotype.
    public static func indels(fromVCFLines lines: [String]) -> [Indel] {
        var result: [Indel] = []
        for line in lines {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let position = Int(fields[1]) else { continue }
            guard fields.count < 7 || passesFilter(String(fields[6])) else { continue }

            let reference = String(fields[3])
            let alternates = fields[4].split(separator: ",").map(String.init)
            guard let alternate = appliedAlternate(alternates: alternates, fields: fields) else {
                continue
            }
            guard reference.count != alternate.count else { continue }
            result.append(Indel(position: position,
                                referenceLength: reference.count,
                                alternateLength: alternate.count))
        }
        return result
    }

    /// Whether a VCF FILTER field means the record was applied.
    private static func passesFilter(_ filter: String) -> Bool {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "." || trimmed == "PASS"
    }

    /// The ALT allele `bcftools consensus` would apply, or nil when it cannot
    /// be determined without guessing.
    private static func appliedAlternate(
        alternates: [String],
        fields: [Substring]
    ) -> String? {
        guard !alternates.isEmpty else { return nil }
        if alternates.count == 1 {
            return alternates[0]
        }
        guard let index = genotypeAlleleIndex(fields: fields) else { return nil }
        // Index 0 is the reference allele: nothing is applied.
        guard index > 0, index <= alternates.count else { return nil }
        return alternates[index - 1]
    }

    /// The single allele index named by the first sample's GT, or nil when
    /// there is no GT, it is missing, or it names more than one allele.
    ///
    /// A heterozygous call does not identify one sequence to lay over the
    /// reference, so it is treated as undeterminable rather than resolved to
    /// either side.
    private static func genotypeAlleleIndex(fields: [Substring]) -> Int? {
        guard fields.count >= 10 else { return nil }
        let format = fields[8].split(separator: ":", omittingEmptySubsequences: false)
        guard let genotypeField = format.firstIndex(of: "GT") else { return nil }
        let sample = fields[9].split(separator: ":", omittingEmptySubsequences: false)
        guard genotypeField < sample.count else { return nil }

        let alleles = sample[genotypeField]
            .split(whereSeparator: { $0 == "/" || $0 == "|" })
            .map(String.init)
        guard !alleles.isEmpty else { return nil }

        // Every allele must parse and they must all agree. A missing call
        // (`.`) or a heterozygous call does not identify one sequence to lay
        // over the reference.
        let parsed = alleles.compactMap { Int($0) }
        guard parsed.count == alleles.count else { return nil }
        let indices = Set(parsed)
        guard indices.count == 1 else { return nil }
        return indices.first
    }
}
