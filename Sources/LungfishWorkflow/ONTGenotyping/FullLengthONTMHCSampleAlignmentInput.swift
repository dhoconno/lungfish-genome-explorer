import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCSampleAlignmentInput: Sendable, Equatable {
    public let sampleID: String
    public let originalClustersFASTAURL: URL
    public let clusterRecords: [FullLengthONTMHCClusterFASTARecord]

    public init(
        sampleID: String,
        originalClustersFASTAURL: URL,
        clusterRecords: [FullLengthONTMHCClusterFASTARecord]
    ) {
        self.sampleID = sampleID
        self.originalClustersFASTAURL = originalClustersFASTAURL.standardizedFileURL
        self.clusterRecords = clusterRecords
    }
}
