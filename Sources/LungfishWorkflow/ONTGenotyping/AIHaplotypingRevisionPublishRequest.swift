import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

public struct AIHaplotypingRevisionPublishRequest {
    public let bundleURL: URL
    public let result: ONTGenotypeResultBundleData
    public let sidecarURL: URL?
    public let sidecar: GenotypeAnnotationSidecar?
    public let expectedSidecarRevision: GenotypeAnnotationSidecarRevision
    public let runnerOutput: AIHaplotypingRunnerOutput
    public let context: AIHaplotypingRevisionPublishContext

    public init(
        bundleURL: URL,
        result: ONTGenotypeResultBundleData,
        sidecarURL: URL? = nil,
        sidecar: GenotypeAnnotationSidecar? = nil,
        expectedSidecarRevision: GenotypeAnnotationSidecarRevision,
        runnerOutput: AIHaplotypingRunnerOutput,
        context: AIHaplotypingRevisionPublishContext
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.result = result
        self.sidecarURL = sidecarURL?.standardizedFileURL
        self.sidecar = sidecar
        self.expectedSidecarRevision = expectedSidecarRevision
        self.runnerOutput = runnerOutput
        self.context = context
    }
}
