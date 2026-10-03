import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct PrimalScheme3DesignRequest: Sendable {
    public let inputURLs: [URL]
    public let destinationURL: URL
    public let options: PrimalScheme3DesignOptions
    public let grouping: PrimerAnalysisGrouping
    public let invocation: PrimerAnalysisWrapperInvocation
    public let executableURL: URL?
    public let expectedInputChecksums: [URL: String]

    public init(inputURLs: [URL], destinationURL: URL, options: PrimalScheme3DesignOptions,
                grouping: PrimerAnalysisGrouping, invocation: PrimerAnalysisWrapperInvocation,
                executableURL: URL? = nil, expectedInputChecksums: [URL: String] = [:]) {
        self.inputURLs = inputURLs
        self.destinationURL = destinationURL
        self.options = options
        self.grouping = grouping
        self.invocation = invocation
        self.executableURL = executableURL
        self.expectedInputChecksums = expectedInputChecksums
    }
}
