import Foundation
import LungfishCore
import LungfishIO

public protocol ONTGenotypingMappingRunning: Sendable {
    func runMapping(
        request: MappingRunRequest,
        progressHandler: ManagedMappingPipeline.ProgressHandler?
    ) async throws -> MappingResult
}
