import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

public struct AIHaplotypingRevisionPublishResult {
    public let revision: ONTGenotypeHaplotypeAnalysisRevision
    public let manifest: ONTGenotypeResultBundleManifest
    public let analysis: GenotypeHaplotypeAnalysis
    public let sidecar: GenotypeAnnotationSidecar?
    public let revisionDirectoryURL: URL
    public let provenanceURL: URL
}
