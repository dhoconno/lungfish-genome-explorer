import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCManualHaplotypeWorkbookRow: Codable, Equatable, Sendable {
    let locus: String
    let slot: HaplotypeSlot
    let rowLabel: String

    private enum CodingKeys: String, CodingKey {
        case locus
        case slot
        case rowLabel = "row_label"
    }
}
