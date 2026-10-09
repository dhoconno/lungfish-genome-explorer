import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeResultHighlightScope: String, CaseIterable, Equatable {
    case selectedCell
    case selectedRow
    case clear

    public var displayName: String {
        switch self {
        case .selectedCell:
            return "Selected Cell"
        case .selectedRow:
            return "Selected Genotype Row"
        case .clear:
            return "Clear Highlight"
        }
    }
}
