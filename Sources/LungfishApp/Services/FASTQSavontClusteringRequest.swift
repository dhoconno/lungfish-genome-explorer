import Foundation
import LungfishWorkflow

struct FASTQSavontClusteringRequest: Sendable, Equatable {
    let inputURLs: [URL]
    let outputDirectoryURL: URL
    let singleInputOutputName: String?
    let threads: Int
    let qualityValueCutoff: Int
    let minimumClusterSize: Int
    let minimumReadLength: Int?
    let maximumReadLength: Int?
    let singleStrand: Bool

    static func defaultOutputBaseName(for inputURL: URL) -> String {
        let namingURL = inputURL.pathExtension.lowercased() == "lungfishfastq"
            ? inputURL.deletingPathExtension()
            : inputURL
        return SavontClusteringRunRequest.defaultOutputBaseName(for: namingURL)
    }
}
