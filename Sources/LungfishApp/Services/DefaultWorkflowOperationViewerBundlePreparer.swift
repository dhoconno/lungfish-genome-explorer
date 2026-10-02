import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct DefaultWorkflowOperationViewerBundlePreparer: WorkflowOperationViewerBundlePreparing {
    func prepareBaseBundle(
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws {
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundleURL,
            viewerBundleURL: viewerBundleURL,
            fileManager: fileManager
        )
    }
}
