import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let outputDirectory: URL
    public let outputName: String
    public let projectURL: URL?
    public let threads: Int
    public let minSupport: Int
    public let extraArguments: [String]

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        outputDirectory: URL,
        outputName: String = "ont-genotyping-report",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minSupport: Int = 1,
        extraArguments: [String] = []
    ) {
        self.inputFASTQURLs = inputFASTQURLs.map(\.standardizedFileURL)
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = Self.sanitizedOutputName(outputName)
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.minSupport = max(1, minSupport)
        self.extraArguments = extraArguments
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).csv")
    }

    public var argv: [String] {
        var values = [CLICommandIdentity.executableName, "fastq", "ont-genotype"]
        values.append(contentsOf: inputFASTQURLs.map(\.path))
        values += [
            "--reference", referenceSourceURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--min-support", String(minSupport),
        ]
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if !extraArguments.isEmpty {
            values += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        return values
    }

    private static func sanitizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "ont-genotyping-report" : collapsed
    }
}
