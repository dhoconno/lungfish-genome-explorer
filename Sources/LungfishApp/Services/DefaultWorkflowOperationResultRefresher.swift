import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct DefaultWorkflowOperationResultRefresher: WorkflowOperationResultRefreshing {
    @MainActor
    func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL) async {
        guard let splitViewController = AppDelegate.shared?
            .targetMainWindowController(routeContext: routeContext)?
            .mainSplitViewController else {
            return
        }

        if MappingResult.exists(in: preferredSelectionURL) {
            splitViewController.refreshSidebarAndDisplayMappingResult(at: preferredSelectionURL)
            return
        }

        // The recursive project scan runs off the main actor; only the cheap
        // apply and the selection happen back on it once the scan returns.
        await splitViewController.sidebarController.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: true)?.value
        _ = splitViewController.sidebarController.selectItem(
            forURL: preferredSelectionURL.standardizedFileURL
        )
    }
}
