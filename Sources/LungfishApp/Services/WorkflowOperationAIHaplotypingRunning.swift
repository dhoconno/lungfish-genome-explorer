import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

protocol WorkflowOperationAIHaplotypingRunning: Sendable {
    @MainActor
    func run(
        bundleURL: URL,
        mode: AIHaplotypingPromptMode,
        routeContext: OperationRouteContext?,
        parentOperationID: UUID?
    ) async throws -> WorkflowOperationAIHaplotypingPublication
}
