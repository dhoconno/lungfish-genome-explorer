import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCCohortAlignmentBuildRequest: Sendable, Equatable {
    public let samples: [FullLengthONTMHCSampleAlignmentInput]
    public let referenceAlleleFASTAURL: URL
    public let threads: Int
    public let outputDirectoryURL: URL
    public let workDirectoryURL: URL
    public let keepIntermediates: Bool
    public let deferTemporaryWorkDirectoryCleanup: Bool
    public let allowEmptyCohort: Bool

    public init(
        samples: [FullLengthONTMHCSampleAlignmentInput],
        referenceAlleleFASTAURL: URL,
        threads: Int,
        outputDirectoryURL: URL,
        workDirectoryURL: URL,
        keepIntermediates: Bool,
        deferTemporaryWorkDirectoryCleanup: Bool = false,
        allowEmptyCohort: Bool = false
    ) {
        self.samples = samples
        self.referenceAlleleFASTAURL = referenceAlleleFASTAURL.standardizedFileURL
        self.threads = max(1, threads)
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.workDirectoryURL = workDirectoryURL.standardizedFileURL
        self.keepIntermediates = keepIntermediates
        self.deferTemporaryWorkDirectoryCleanup = deferTemporaryWorkDirectoryCleanup
        self.allowEmptyCohort = allowEmptyCohort
    }
}
