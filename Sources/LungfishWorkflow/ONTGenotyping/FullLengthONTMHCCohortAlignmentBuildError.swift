import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCCohortAlignmentBuildError: Error, LocalizedError, Sendable {
    public let message: String
    public let retainedWorkDirectoryURL: URL
    public let retainedPublicationDirectoryURL: URL?
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let toolVersions: [FullLengthONTMHCToolVersionRecord]
    public let toolVersionDiscoveryRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let artifactDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let plannedPublicationMappings: [FullLengthONTMHCArtifactPublicationMapping]
    public let publicationRecord: FullLengthONTMHCAlignmentDirectoryPublicationRecord?
    public let transformationRecords: [FullLengthONTMHCInProcessTransformationRecord]
    public let wasCancelled: Bool

    public var errorDescription: String? { message }
}
