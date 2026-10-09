import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeSummaryViewMode: String, CaseIterable, Equatable {
    case outline
    case matrix

    public var displayName: String {
        switch self {
        case .outline: return "Outline"
        case .matrix:  return "Matrix"
        }
    }
}
