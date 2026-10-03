import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCCohortAlignmentResult: Sendable, Equatable {
    public let bamURL: URL
    public let baiURL: URL
    public let sampleMappings: [FullLengthONTMHCSampleAlignmentMapping]
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let temporaryWorkDirectoryURL: URL
    public let mergedBAMURL: URL
    public private(set) var retainedPublicationDirectoryURL: URL?
    public private(set) var publicationCleanupError: String?
    public let toolVersions: [FullLengthONTMHCToolVersionRecord]
    public let toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let artifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let finalArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let temporaryArtifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let publicationMappings: [FullLengthONTMHCArtifactPublicationMapping]
    public private(set) var publicationRecord: FullLengthONTMHCAlignmentDirectoryPublicationRecord?
    public let transformationRecords: [FullLengthONTMHCInProcessTransformationRecord]
    public private(set) var cleanupDiagnostics: [FullLengthONTMHCCleanupDiagnostic]
    public let requiresTemporaryWorkDirectoryCleanup: Bool

    mutating func attachCleanup(
        retainedPublicationDirectoryURL: URL?,
        publicationCleanupError: String?,
        diagnostics: [FullLengthONTMHCCleanupDiagnostic]
    ) {
        self.retainedPublicationDirectoryURL = retainedPublicationDirectoryURL
        self.publicationCleanupError = publicationCleanupError
        cleanupDiagnostics = diagnostics
    }

    mutating func attachPublicationRecord(
        _ record: FullLengthONTMHCAlignmentDirectoryPublicationRecord
    ) {
        publicationRecord = record
    }
}
