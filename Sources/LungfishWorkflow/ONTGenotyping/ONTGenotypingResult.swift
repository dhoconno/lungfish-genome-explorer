import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingResult: Sendable, Codable, Equatable {
    public let reportCSVURL: URL
    public let outputDirectory: URL
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let sampleResults: [ONTGenotypingSampleResult]
}
