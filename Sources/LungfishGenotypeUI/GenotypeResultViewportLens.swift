import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeResultViewportLens: String, CaseIterable, Equatable {
    case summary
    case review
    case audit

    public var displayName: String {
        switch self {
        case .summary: return "Summary"
        case .review:  return "Review"
        case .audit:   return "Audit"
        }
    }

    public var inspectorSystemImage: String {
        switch self {
        case .summary: return "tablecells"
        case .review:  return "checklist"
        case .audit:   return "doc.text.magnifyingglass"
        }
    }

    public var identifier: String {
        rawValue
    }
}
