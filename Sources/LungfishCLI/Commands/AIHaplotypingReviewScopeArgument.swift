import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AIHaplotypingReviewScopeArgument: String, CaseIterable, ExpressibleByArgument {
    case all
    case unresolvedOnly = "unresolved-only"

    var workflowScope: AIHaplotypingReviewScope {
        switch self {
        case .all: return .all
        case .unresolvedOnly: return .unresolvedOnly
        }
    }
}
