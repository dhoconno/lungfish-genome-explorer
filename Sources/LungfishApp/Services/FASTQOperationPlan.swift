import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct FASTQOperationPlan: Sendable, Equatable {
    let originalRequest: FASTQOperationLaunchRequest
    let resolvedRequest: FASTQOperationLaunchRequest
    let outputTarget: URL
    let outputKind: FASTQOperationExecutionOutputKind
}
