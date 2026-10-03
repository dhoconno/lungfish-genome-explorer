import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCSampleAlignmentMapping: Sendable, Equatable {
    public let sampleID: String
    public let readGroupID: String
    public let readGroupSample: String
    public let originalClustersFASTAURL: URL
    public let namespacedClustersFASTAURL: URL
    public let samURL: URL
    public let unsortedBAMURL: URL
    public let readGroupBAMURL: URL
    public let sortedBAMURL: URL
    public let targets: [FullLengthONTMHCTargetNamespaceMapping]
}
