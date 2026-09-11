import ArgumentParser
import Foundation
import LungfishIO

struct PrimerAnalysisCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analysis",
        abstract: "Inspect saved primer analysis results",
        subcommands: [PrimerAnalysisInspectCommand.self]
    )
}

struct PrimerAnalysisInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Verify stored file integrity and inspect a .lungfishprimeranalysis bundle"
    )

    @Argument(help: "Path to the saved analysis bundle.")
    var bundlePath: String

    @Flag(name: .long, help: "Print the verified manifest as JSON.")
    var json = false

    mutating func run() throws {
        print(try inspectionOutput())
    }

    func inspectionOutput() throws -> String {
        let bundle = try PrimerAnalysisBundle.load(from: URL(fileURLWithPath: bundlePath))
        let manifest = bundle.manifest
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        }
        return """
        Analysis: \(manifest.analysisID.uuidString)
        Run: \(manifest.runID.uuidString)
        Grouping: \(manifest.grouping.rawValue)
        Inputs: \(manifest.inputs.count)
        Results: \(manifest.results.count)
        Artifacts: \(manifest.artifacts.count)
        Integrity verified
        """
    }
}
