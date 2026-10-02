import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

protocol WorkflowOperationResultRefreshing: Sendable {
    @MainActor
    func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL) async
}
