import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeResultPanelLayout: String, CaseIterable, Equatable {
    case listLeading
    case listTrailing
    case listTop

    public var displayName: String {
        switch self {
        case .listLeading:
            return "List Left"
        case .listTrailing:
            return "List Right"
        case .listTop:
            return "List Top"
        }
    }

    public var inspectorLabel: String {
        switch self {
        case .listTrailing:
            return "Detail | List"
        case .listLeading:
            return "List | Detail"
        case .listTop:
            return "List Over Detail"
        }
    }

    public var inspectorSystemImage: String {
        switch self {
        case .listTrailing:
            return "sidebar.left"
        case .listLeading:
            return "sidebar.right"
        case .listTop:
            return "rectangle.split.1x2"
        }
    }
}
