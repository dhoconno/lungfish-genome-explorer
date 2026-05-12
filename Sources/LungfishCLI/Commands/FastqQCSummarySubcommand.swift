import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqQCSummarySubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qc-summary",
        abstract: "Compute a JSON QC summary for FASTQ input files"
    )

    @Argument(help: "Input FASTQ file(s)")
    var inputs: [String]

    @OptionGroup var output: OutputOptions

    func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("Specify at least one input FASTQ file")
        }

        try output.validateOutput()

        let reader = FASTQReader(validateSequence: false)
        let startedAt = Date()
        let inputURLs = try inputs.map(validateInput)
        var summaries: [FastqQCSummaryEntry] = []
        summaries.reserveCapacity(inputs.count)

        for inputURL in inputURLs {
            let result = try await reader.computeStatistics(from: inputURL, sampleLimit: 0)
            summaries.append(FastqQCSummaryEntry(
                input: inputURL.path,
                statistics: result.statistics
            ))
        }

        let report = FastqQCSummaryReport(inputs: summaries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let outputURL = URL(fileURLWithPath: output.output)
        try data.write(to: outputURL, options: [.atomic])

        var cliArguments = ["qc-summary"] + inputURLs.map(\.path) + ["--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        let parameters: [String: ParameterValue] = [
            "inputs": .array(inputURLs.map { .file($0) }),
            "output": .file(outputURL),
            "force": .boolean(output.force),
            "compress": .boolean(output.compress)
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq qc-summary",
            parameters: parameters,
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            toolName: "lungfish fastq qc-summary",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish", "fastq"] + cliArguments,
            stepCommand: ["lungfish", "fastq"] + cliArguments,
            inputs: inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input) },
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: .json, role: .output)],
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL.deletingLastPathComponent()
        )
    }
}

private struct FastqQCSummaryReport: Codable, Equatable {
    let inputs: [FastqQCSummaryEntry]
}

private struct FastqQCSummaryEntry: Codable, Equatable {
    let input: String
    let statistics: FASTQDatasetStatistics
}
