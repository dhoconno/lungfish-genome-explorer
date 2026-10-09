import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeResultCellColorMode: String, CaseIterable, Equatable {
    case support
    case haplotype
    case highlights
    case none

    public var displayName: String {
        switch self {
        case .support:
            return "Support"
        case .haplotype:
            return "Haplotype"
        case .highlights:
            return "Highlights"
        case .none:
            return "None"
        }
    }
}
