import Foundation
import Darwin
import LungfishCore
import LungfishIO

enum ONTGenotypingProcessWaitError: Error, Equatable, Sendable {
    case timedOut(tool: String, seconds: TimeInterval)
    case exitedNonzero(tool: String, status: Int32)
}
