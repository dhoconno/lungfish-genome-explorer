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

    static func safeSingleInputOutputName(
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
