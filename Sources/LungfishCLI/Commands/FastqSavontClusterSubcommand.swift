import ArgumentParser
import Foundation
import LungfishWorkflow

struct FastqSavontClusterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "savont-cluster",
        abstract: "Cluster FASTQ reads into counted consensus sequences with Savont"
    )

    struct Runtime {
        let run: (SavontClusteringRunRequest) async throws -> SavontClusteringResult

        static func live() -> Runtime {
            Runtime { request in
                try await SavontClusteringPipeline().run(request)
            }
        }
    }

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("output"), help: "Output counted-cluster FASTA file")
    var output: String

    @Option(name: .customLong("threads"), help: "Threads for Savont")
    var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    @Option(
        name: .customLong("quality-value-cutoff"),
        help: "Savont quality-value cutoff"
    )
    var qualityValueCutoff: Int = 90

    @Option(
        name: .customLong("min-cluster-size"),
        help: "Minimum reads per cluster"
    )
    var minimumClusterSize: Int = 3

    @Option(name: .customLong("min-read-length"), help: "Optional minimum read length")
    var minimumReadLength: Int?

    @Option(name: .customLong("max-read-length"), help: "Optional maximum read length")
    var maximumReadLength: Int?

    @Flag(name: .customLong("single-strand"), help: "Run Savont in single-strand mode")
    var singleStrand = false

    func run() async throws {
        try await executeForTesting(
            runtime: .live(),
            emitStandardOutput: { FileHandle.standardOutput.write($0) },
            emitStandardError: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }

    func makeRequestForTesting() throws -> SavontClusteringRunRequest {
        try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: input),
            outputFASTAURL: URL(fileURLWithPath: output),
            threads: threads,
            qualityValueCutoff: qualityValueCutoff,
            minimumClusterSize: minimumClusterSize,
            minimumReadLength: minimumReadLength,
            maximumReadLength: maximumReadLength,
            singleStrand: singleStrand
        )
    }

    func executeForTesting(
        runtime: Runtime,
        emitStandardOutput: (Data) -> Void,
        emitStandardError: (String) -> Void
    ) async throws {
        let request = try makeRequestForTesting()
        emitStandardError(
            "Savont clustering started: \(request.inputFASTQURL.path) -> \(request.outputFASTAURL.path)\n"
        )
        let result = try await runtime.run(request)
        let payload = FastqSavontClusterPayload(result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(payload)
        data.append(contentsOf: Data("\n".utf8))

        if result.usedSingleThreadFallback {
            emitStandardError("warning: Savont used the single-thread fallback.\n")
        }
        if result.usedSingleStrandFallback {
            emitStandardError("warning: Savont used the single-strand fallback.\n")
        }
        let clusterNoun = result.summary.clusterCount == 1 ? "cluster" : "clusters"
        let readNoun = result.summary.totalSupportingReads == 1 ? "read" : "reads"
        emitStandardError(
            "Savont clustering complete: \(result.summary.clusterCount) \(clusterNoun), "
                + "\(result.summary.totalSupportingReads) supporting \(readNoun).\n"
        )
        if !result.cleanupPendingURLs.isEmpty {
            let paths = result.cleanupPendingURLs.map(\.path).joined(separator: ", ")
            emitStandardError("warning: Savont cleanup is pending for: \(paths)\n")
        }
        emitStandardOutput(data)
    }
}

private struct FastqSavontClusterPayload: Encodable {
    let outputFASTAPath: String
    let provenancePath: String
    let clusterCount: Int
    let totalSupportingReads: Int
    let usedSingleThreadFallback: Bool
    let usedSingleStrandFallback: Bool
    let cleanupPendingPaths: [String]

    init(result: SavontClusteringResult) {
        outputFASTAPath = result.outputFASTAURL.path
        provenancePath = result.provenanceURL.path
        clusterCount = result.summary.clusterCount
        totalSupportingReads = result.summary.totalSupportingReads
        usedSingleThreadFallback = result.usedSingleThreadFallback
        usedSingleStrandFallback = result.usedSingleStrandFallback
        cleanupPendingPaths = result.cleanupPendingURLs.map(\.path)
    }
}
