import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeResultHighlightChannel: String, CaseIterable, Equatable {
    case fill
    case border

    public var displayName: String {
        switch self {
        case .fill:
            return "Fill"
        case .border:
            return "Border"
        }
    }
}
