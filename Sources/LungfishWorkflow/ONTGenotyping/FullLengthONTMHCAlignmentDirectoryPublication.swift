import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCAlignmentDirectoryPublication: Sendable, Equatable {
    public let retiredDirectoryURL: URL?
    public let record: FullLengthONTMHCAlignmentDirectoryPublicationRecord

    public init(
        retiredDirectoryURL: URL?,
        record: FullLengthONTMHCAlignmentDirectoryPublicationRecord
    ) {
        self.retiredDirectoryURL = retiredDirectoryURL
        self.record = record
    }
}
