import Foundation

public enum GenotypeManualHaplotypeLocus: String, Codable, CaseIterable, Sendable {
    case a = "MHC-A"
    case b = "MHC-B"
    case drb = "MHC-DRB"
    case dqa = "MHC-DQA"
    case dqb = "MHC-DQB"
    case dpa = "MHC-DPA"
    case dpb = "MHC-DPB"

    public var workbookLabel: String { rawValue }

    public init?(normalizing rawLocus: String) {
        var normalized = rawLocus.replacingOccurrences(of: "_", with: "-")
        if normalized.uppercased().hasPrefix("MHC ") {
            normalized = "MHC-" + normalized.dropFirst(4)
        }
        let canonical = GenotypeHaplotypeLocusResolver.canonicalLocusName(
            normalized
        )
        guard let value = Self(rawValue: canonical) else { return nil }
        self = value
    }
}
