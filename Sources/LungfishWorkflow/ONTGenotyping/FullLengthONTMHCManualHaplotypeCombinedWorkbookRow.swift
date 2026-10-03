import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCManualHaplotypeCombinedWorkbookRow:
    Codable, Equatable, Sendable
{
    let componentLoci: [String]
    let slot: HaplotypeSlot
    let rowLabel: String
    let compositionPolicy: String

    private enum CodingKeys: String, CodingKey {
        case componentLoci = "component_loci"
        case slot
        case rowLabel = "row_label"
        case compositionPolicy = "composition_policy"
    }
}
