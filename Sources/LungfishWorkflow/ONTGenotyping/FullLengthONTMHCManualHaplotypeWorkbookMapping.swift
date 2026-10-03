import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

enum FullLengthONTMHCManualHaplotypeWorkbookMapping {
    static let rows: [FullLengthONTMHCManualHaplotypeWorkbookRow] =
        GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
            HaplotypeSlot.allCases.map { slot in
                FullLengthONTMHCManualHaplotypeWorkbookRow(
                    locus: locus.rawValue,
                    slot: slot,
                    rowLabel:
                        "\(locus.rawValue) Haplotype \(slot == .h1 ? "1" : "2")"
                )
            }
        }

    static let legacyCombinedRows:
        [FullLengthONTMHCManualHaplotypeCombinedWorkbookRow] = [
            ("MHC-DQA/B", ["MHC-DQA", "MHC-DQB"]),
            ("MHC-DPA/B", ["MHC-DPA", "MHC-DPB"]),
        ].flatMap { label, componentLoci in
            HaplotypeSlot.allCases.map { slot in
                FullLengthONTMHCManualHaplotypeCombinedWorkbookRow(
                    componentLoci: componentLoci,
                    slot: slot,
                    rowLabel:
                        "\(label) Haplotype \(slot == .h1 ? "1" : "2")",
                    compositionPolicy:
                        "collapse-identical-otherwise-locus-tagged"
                )
            }
        }
}
