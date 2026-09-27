import Foundation

/// Checks that each fixed oligo really occurs in the template, and reports
/// where, before Primer3 runs.
///
/// Primer3 silently returns no pairs when a fixed oligo is not present, which
/// looks identical to a design whose thermodynamics failed. Locating each oligo
/// up front turns that into a specific, actionable error, and the reported
/// positions are what the GUI shows and provenance records.
public enum Primer3FixedOligoValidation {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case leftPrimer
        case rightPrimer
        case probe

        public var displayName: String {
            switch self {
            case .leftPrimer: "Forward primer"
            case .rightPrimer: "Reverse primer"
            case .probe: "Probe"
            }
        }

        /// The Boulder tag this role writes.
        public var boulderKey: String {
            switch self {
            case .leftPrimer: "SEQUENCE_PRIMER"
            case .rightPrimer: "SEQUENCE_PRIMER_REVCOMP"
            case .probe: "SEQUENCE_INTERNAL_OLIGO"
            }
        }
    }

    /// Where a fixed oligo was found on the template.
    public struct Placement: Codable, Equatable, Sendable {
        public let role: Role
        /// The sequence as the caller gave it, 5'->3' as ordered.
        public let sequence: String
        /// 1-based inclusive template start of the matched stretch.
        public let start: Int
        /// 1-based inclusive template end of the matched stretch.
        public let end: Int
        /// True when the match was found on the reverse strand, which is the
        /// expected case for a reverse primer.
        public let matchedReverseComplement: Bool

        public init(role: Role, sequence: String, start: Int, end: Int, matchedReverseComplement: Bool) {
            self.role = role
            self.sequence = sequence
            self.start = start
            self.end = end
            self.matchedReverseComplement = matchedReverseComplement
        }

        /// The 3' end position, which is the base a discriminating column must
        /// line up with for the mismatch to block extension.
        public var threePrimeEnd: Int { matchedReverseComplement ? start : end }
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case notFound(Role, String)
        case ambiguous(Role, String, count: Int)
        case invalidSymbols(Role, String)
        case forcedEndOutOfRange(String, Int, templateLength: Int)

        public var errorDescription: String? {
            switch self {
            case .notFound(let role, let sequence):
                "\(role.displayName) \(sequence) does not occur in the template. Check the sequence and its orientation; a reverse primer is given 5'->3' as ordered."
            case .ambiguous(let role, let sequence, let count):
                "\(role.displayName) \(sequence) occurs \(count) times in the template, so its position is ambiguous."
            case .invalidSymbols(let role, let sequence):
                "\(role.displayName) \(sequence) contains symbols that are not A, C, G or T."
            case .forcedEndOutOfRange(let name, let position, let templateLength):
                "\(name) position \(position) is outside the template, which is \(templateLength) bases long."
            }
        }
    }

    /// Locates every fixed oligo on `template` and validates the forced ends.
    ///
    /// A reverse primer is given 5'->3' as ordered, so it is its reverse
    /// complement that appears in the template; both strands are searched and
    /// which one matched is recorded.
    public static func validate(
        _ oligos: Primer3FixedOligos,
        template: String
    ) throws -> [Placement] {
        let upper = template.uppercased()
        var placements: [Placement] = []
        for (role, sequence) in [
            (Role.leftPrimer, oligos.leftPrimer),
            (Role.rightPrimer, oligos.rightPrimer),
            (Role.probe, oligos.probe),
        ] {
            guard let sequence else { continue }
            placements.append(try locate(role: role, sequence: sequence, template: upper))
        }
        for (name, position) in [
            ("SEQUENCE_FORCE_LEFT_END", oligos.forceLeftEnd),
            ("SEQUENCE_FORCE_RIGHT_END", oligos.forceRightEnd),
        ] {
            guard let position else { continue }
            guard position >= 1, position <= upper.count else {
                throw Failure.forcedEndOutOfRange(name, position, templateLength: upper.count)
            }
        }
        return placements
    }

    private static func locate(role: Role, sequence: String, template: String) throws -> Placement {
        guard sequence.allSatisfy({ "ACGT".contains($0) }) else {
            throw Failure.invalidSymbols(role, sequence)
        }
        let forward = occurrences(of: sequence, in: template)
        let reverse = occurrences(of: reverseComplement(sequence), in: template)
        let total = forward.count + reverse.count
        guard total > 0 else { throw Failure.notFound(role, sequence) }
        guard total == 1 else { throw Failure.ambiguous(role, sequence, count: total) }
        if let start = forward.first {
            return Placement(
                role: role, sequence: sequence,
                start: start + 1, end: start + sequence.count,
                matchedReverseComplement: false)
        }
        let start = reverse[0]
        return Placement(
            role: role, sequence: sequence,
            start: start + 1, end: start + sequence.count,
            matchedReverseComplement: true)
    }

    /// 0-based start offsets of every occurrence, including overlapping ones.
    static func occurrences(of needle: String, in haystack: String) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        let hay = Array(haystack)
        let pin = Array(needle)
        var found: [Int] = []
        for start in 0...(hay.count - pin.count) where Array(hay[start..<(start + pin.count)]) == pin {
            found.append(start)
        }
        return found
    }

    public static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base in
            switch base {
            case "A": "T"
            case "T": "A"
            case "G": "C"
            case "C": "G"
            default: base
            }
        })
    }
}
