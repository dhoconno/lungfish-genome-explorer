import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

protocol WorkflowOperationBAMImporting: Sendable {
    func importBAM(
        bamURL: URL,
        bundleURL: URL,
        name: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws
}
