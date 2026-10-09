import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeMatrixCommentScope: String, CaseIterable, Equatable, Identifiable, Sendable {
    case cell
    case alleleRow
    case sampleColumn

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cell:
            return "Cell"
        case .alleleRow:
            return "Allele Row"
        case .sampleColumn:
            return "Sample Column"
        }
    }

}
