import Foundation
import Darwin
import LungfishIO

protocol FullLengthONTMHCAlignmentDirectoryRenaming: Sendable {
    func rename(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL,
        flags: UInt32
    ) -> FullLengthONTMHCAlignmentDirectoryRenameAttempt
}
