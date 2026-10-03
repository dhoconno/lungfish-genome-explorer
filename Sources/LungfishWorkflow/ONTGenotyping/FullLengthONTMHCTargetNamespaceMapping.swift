import Foundation
import Darwin
import LungfishIO

public struct FullLengthONTMHCTargetNamespaceMapping: Sendable, Equatable, Codable {
    public let originalClusterID: String
    public let namespacedTargetID: String

    public init(originalClusterID: String, namespacedTargetID: String) {
        self.originalClusterID = originalClusterID
        self.namespacedTargetID = namespacedTargetID
    }
}
