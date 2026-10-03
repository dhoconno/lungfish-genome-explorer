import Foundation
import LungfishCore
import LungfishIO

public struct MSAReferenceBundleBuildResult: Sendable, Equatable {
    public let bundleURL: URL
    public let sequenceCount: Int
    public let totalLength: Int
    public let warnings: [String]

    public init(bundleURL: URL, sequenceCount: Int, totalLength: Int, warnings: [String]) {
        self.bundleURL = bundleURL
        self.sequenceCount = sequenceCount
        self.totalLength = totalLength
        self.warnings = warnings
    }
}
