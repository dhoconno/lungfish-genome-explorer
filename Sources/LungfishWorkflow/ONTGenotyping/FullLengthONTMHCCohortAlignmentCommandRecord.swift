import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCCohortAlignmentCommandRecord: Sendable, Equatable {
    public let executableURL: URL
    public let toolVersion: String?
    public let argv: [String]
    public let arguments: [String]
    public let inputs: [URL]
    public let outputs: [URL]
    public let inputDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let outputDescriptors: [FullLengthONTMHCArtifactDescriptor]
    public let descriptorCaptureErrors: [FullLengthONTMHCArtifactDescriptorCaptureError]
    public let stdoutLogDescriptor: FullLengthONTMHCArtifactDescriptor
    public let stderrLogDescriptor: FullLengthONTMHCArtifactDescriptor
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String
    public let wasCancelled: Bool
    public let startedAt: Date
    public let completedAt: Date
    public let wallTime: TimeInterval
}
