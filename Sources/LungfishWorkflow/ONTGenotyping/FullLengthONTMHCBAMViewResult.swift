import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCBAMViewResult: Sendable, Equatable {
    public let samURL: URL
    public let commandRecord: FullLengthONTMHCCohortAlignmentCommandRecord
}
