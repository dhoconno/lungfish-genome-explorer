import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

protocol WorkflowOperationViewerBundlePreparing: Sendable {
    func prepareBaseBundle(
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws
}
