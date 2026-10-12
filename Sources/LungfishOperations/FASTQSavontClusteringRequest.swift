import Foundation
import LungfishWorkflow

package struct FASTQSavontClusteringRequest: Sendable, Equatable {
    package let inputURLs: [URL]
    package let outputDirectoryURL: URL
    package let singleInputOutputName: String?
    package let threads: Int
    package let qualityValueCutoff: Int
    package let minimumClusterSize: Int
    package let minimumReadLength: Int?
    package let maximumReadLength: Int?
    package let singleStrand: Bool

    package init(
        inputURLs: [URL],
        outputDirectoryURL: URL,
        singleInputOutputName: String?,
        threads: Int,
        qualityValueCutoff: Int,
        minimumClusterSize: Int,
        minimumReadLength: Int?,
        maximumReadLength: Int?,
        singleStrand: Bool
    ) {
        self.inputURLs = inputURLs
        self.outputDirectoryURL = outputDirectoryURL
        self.singleInputOutputName = singleInputOutputName
        self.threads = threads
        self.qualityValueCutoff = qualityValueCutoff
        self.minimumClusterSize = minimumClusterSize
        self.minimumReadLength = minimumReadLength
        self.maximumReadLength = maximumReadLength
        self.singleStrand = singleStrand
    }

    package static func defaultOutputBaseName(for inputURL: URL) -> String {
        let namingURL = inputURL.pathExtension.lowercased() == "lungfishfastq"
            ? inputURL.deletingPathExtension()
            : inputURL
        return SavontClusteringRunRequest.defaultOutputBaseName(for: namingURL)
    }

    package static func safeSingleInputOutputName(
        _ rawName: String?,
        outputDirectoryURL: URL
    ) -> String? {
        guard let rawName else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            return nil
        }

        let outputDirectory = outputDirectoryURL.standardizedFileURL
        let candidate = outputDirectory.appendingPathComponent(name).standardizedFileURL
        guard candidate.deletingLastPathComponent() == outputDirectory,
              candidate.lastPathComponent == name else {
            return nil
        }
        return name
    }
}
