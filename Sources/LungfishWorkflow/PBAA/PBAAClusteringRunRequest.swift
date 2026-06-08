import Foundation
import LungfishIO

public struct PBAAClusteringRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let inputFormat: SequenceFormat
    public let guideSourceURL: URL
    public let outputDirectory: URL
    public let outputName: String
    public let prefix: String
    public let threads: Int
    public let seed: Int
    public let extraArgumentsText: String
    public let extraArguments: [String]
    public let containerPins: PBAAContainerPins

    public var rawPBAAOutputDirectory: URL {
        outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
    }

    public init(
        inputFASTQURL: URL,
        guideSourceURL: URL,
        outputDirectory: URL,
        outputName: String,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        seed: Int = 1984,
        inputFormat: SequenceFormat = .fastq,
        extraArgumentsText: String = "",
        containerPins: PBAAContainerPins = .current
    ) throws {
        let sanitizedName = Self.sanitizePrefix(outputName)
        self.inputFASTQURL = inputFASTQURL.standardizedFileURL
        self.inputFormat = inputFormat
        self.guideSourceURL = guideSourceURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = sanitizedName
        self.prefix = sanitizedName
        self.threads = max(1, threads)
        self.seed = seed
        self.extraArgumentsText = extraArgumentsText
        self.extraArguments = try AdvancedCommandLineOptions.parse(extraArgumentsText)
        self.containerPins = containerPins
    }

    static func sanitizePrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "pbaa-clusters" : collapsed
    }
}
