import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingReviewScope: String, Codable, Equatable, Sendable {
    case all
    case unresolvedOnly = "unresolved-only"
}
