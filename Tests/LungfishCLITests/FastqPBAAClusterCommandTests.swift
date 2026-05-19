import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqPBAAClusterCommandTests: XCTestCase {
    private static let demoGuideURL =
        "https://downloads.pacbcloud.com/public/dataset/pbAmpliconAnalysis_HLA/HLA_11locus_clustering_guide.fasta"
    private static let demoReadsURL =
        "https://downloads.pacbcloud.com/public/dataset/pbAmpliconAnalysis_HLA/fastq_600/demultiplex.06896-3.fastq"

    func testFastqCommandRegistersPBAACluster() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("pbaa-cluster"))
    }

    func testPBAAClusterParsesSimpleGuiOptionsAndAdvancedOptions() throws {
        let command = try FastqPBAAClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--guide", "/tmp/guide.fasta",
            "--output-dir", "/tmp/out",
            "--output-name", "sample",
            "--threads", "4",
            "--seed", "7",
            "--extra-args", "--min-cluster-read-count 2",
        ])

        XCTAssertEqual(command.input, "/tmp/reads.fastq")
        XCTAssertEqual(command.guide, "/tmp/guide.fasta")
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.outputName, "sample")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.seed, 7)
        XCTAssertEqual(command.extraArgs, "--min-cluster-read-count 2")
    }

    func testPBAAClusterRuntimeSmokeWhenDockerAndNextflowAreAvailable() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LUNGFISH_RUN_PBAA_RUNTIME_SMOKE"] == "1",
            "Set LUNGFISH_RUN_PBAA_RUNTIME_SMOKE=1 to run the containerized pbAA smoke test"
        )
        try XCTSkipUnless(Self.executableExists("docker"), "Docker is not installed")
        try XCTSkipUnless(Self.executableExists("nextflow"), "Nextflow is not installed")
        try XCTSkipUnless(Self.executableExists("curl"), "curl is not installed")
        try XCTSkipUnless(Self.commandSucceeds("docker", ["info"]), "Docker daemon is not running")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-cli-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let guide = root.appendingPathComponent("guide.fasta")
        let reads = root.appendingPathComponent("reads.fastq")
        try Self.download(Self.demoGuideURL, to: guide)
        try Self.download(Self.demoReadsURL, to: reads)

        let output = root.appendingPathComponent("out", isDirectory: true)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: output,
            outputName: "pbaa_06896-3",
            threads: 2
        )

        let result = try await PBAAClusteringPipeline().run(request)

        XCTAssertEqual(result.referenceBundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.referenceBundleURL.path))
        let passedAttributes = try FileManager.default.attributesOfItem(atPath: result.passedConsensusFASTAURL.path)
        XCTAssertGreaterThan(passedAttributes[.size] as? UInt64 ?? 0, 0)
    }

    private static func executableExists(_ name: String) -> Bool {
        commandSucceeds("which", [name])
    }

    private static func commandSucceeds(_ name: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [name] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func download(_ url: String, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "curl",
            "-L",
            "--fail",
            "--silent",
            "--show-error",
            "-o",
            destination.path,
            url,
        ]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "curl exited with status \(process.terminationStatus)"
            throw NSError(
                domain: "FastqPBAAClusterCommandTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to download \(url): \(message)"]
            )
        }
    }
}
