import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

struct DefaultWorkflowOperationBAMImporter: WorkflowOperationBAMImporting {
    func importBAM(
        bamURL: URL,
        bundleURL: URL,
        name: String?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws {
        _ = try await BAMImportService.importBAM(
            bamURL: bamURL,
            bundleURL: bundleURL,
            name: name,
            progressHandler: progressHandler
        )
    }
}
