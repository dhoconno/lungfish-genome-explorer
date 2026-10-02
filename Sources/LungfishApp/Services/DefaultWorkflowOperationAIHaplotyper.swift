import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

final class DefaultWorkflowOperationAIHaplotyper: WorkflowOperationAIHaplotypingRunning, @unchecked Sendable {
    private let operationCenter: OperationCenter

    @MainActor
    init(operationCenter: OperationCenter = .shared) {
        self.operationCenter = operationCenter
    }

    @MainActor
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext?,
        parentOperationID: UUID?
    ) async throws -> WorkflowOperationAIHaplotypingPublication {
        let published = try await GenotypeAIHaplotypingExecutionService(
            operationCenter: operationCenter
        ).run(
            bundleURL: bundleURL,
            mode: mode,
            routeContext: routeContext,
            parentOperationID: parentOperationID
        )
        return WorkflowOperationAIHaplotypingPublication(
            revision: published.revision,
            analysis: published.analysis,
            provenanceURL: published.provenanceURL
        )
    }
}
