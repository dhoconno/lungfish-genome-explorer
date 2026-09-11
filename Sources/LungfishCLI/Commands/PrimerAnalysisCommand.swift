import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct PrimerAnalysisCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analysis",
        abstract: "Inspect saved primer analysis results",
        subcommands: [PrimerAnalysisInspectCommand.self, PrimerAnalysisAnnotatedReferenceCommand.self]
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


struct PrimerAnalysisAnnotatedReferenceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotated-reference",
        abstract: "Create a native reference with linked annotations from a saved Primer3 result"
    )
    @Argument(help: "Path to the saved .lungfishprimeranalysis bundle.") var bundlePath: String
    @Option(name: .customLong("result-id"), help: "Result UUID from `primers analysis inspect --json`.") var resultID: String
    @Option(name: .customLong("output-directory"), help: "Existing destination directory.") var outputDirectory: String

    func validate() throws {
        guard UUID(uuidString: resultID) != nil else { throw ValidationError("--result-id must be a UUID from the saved analysis.") }
    }
    func run() async throws {
        guard let id = UUID(uuidString: resultID) else { throw ValidationError("Invalid result UUID.") }
        let output = try await PrimerAnalysisAnnotatedReferenceService().createReference(
            analysisURL: URL(fileURLWithPath: bundlePath), resultID: id,
            outputDirectory: URL(fileURLWithPath: outputDirectory), invocationArgv: CommandLine.arguments)
        print("Annotated reference written to \(output.path)")
    }
}
