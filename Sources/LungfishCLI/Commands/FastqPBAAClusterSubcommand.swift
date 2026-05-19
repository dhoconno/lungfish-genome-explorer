import ArgumentParser
import Foundation
import LungfishWorkflow

struct FastqPBAAClusterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pbaa-cluster",
        abstract: "Cluster PacBio HiFi amplicon reads with pbAA in pinned containers"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("guide"), help: "Guide FASTA file or .lungfishref bundle")
    var guide: String

    @Option(name: .customLong("output-dir"), help: "Directory for raw outputs and the .lungfishref result")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Output bundle name and pbAA prefix")
    var outputName: String = "pbaa-clusters"

    @Option(name: .customLong("threads"), help: "Threads for pbAA")
    var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    @Option(name: .customLong("seed"), help: "pbAA random seed")
    var seed: Int = 1984

    @Option(name: .customLong("extra-args"), parsing: .unconditional, help: "Advanced pbAA arguments")
    var extraArgs: String = ""

    func run() async throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: input),
            guideSourceURL: URL(fileURLWithPath: guide),
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            outputName: outputName,
            threads: threads,
            seed: seed,
            extraArgumentsText: extraArgs
        )
        let result = try await PBAAClusteringPipeline().run(request)
        let payload = FastqPBAAClusterPayload(
            referenceBundlePath: result.referenceBundleURL.path,
            rawOutputDirectory: result.rawOutputDirectory.path,
            passedConsensusFASTAPath: result.passedConsensusFASTAURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct FastqPBAAClusterPayload: Encodable {
    let referenceBundlePath: String
    let rawOutputDirectory: String
    let passedConsensusFASTAPath: String
}
