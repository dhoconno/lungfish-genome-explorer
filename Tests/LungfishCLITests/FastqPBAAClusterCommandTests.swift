import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FastqPBAAClusterCommandTests: XCTestCase {
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
        try XCTSkipUnless(Self.commandSucceeds("docker", ["info"]), "Docker daemon is not running")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-cli-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guide = root.appendingPathComponent("guide.fasta")
        let reads = root.appendingPathComponent("reads.fastq")
        let sequence = "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT"
        let qualities = String(repeating: "I", count: sequence.count)
        try ">guide1|target\n\(sequence)\n"
            .write(to: guide, atomically: true, encoding: .utf8)
        try """
        @read1
        \(sequence)
        +
        \(qualities)

        """.write(to: reads, atomically: true, encoding: .utf8)

        let output = root.appendingPathComponent("out", isDirectory: true)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: output,
            outputName: "smoke",
            threads: 1,
            extraArgumentsText: "--min-read-qv 0 --min-cluster-read-count 1 --min-cluster-frequency 0.0 --max-reads-per-guide 1 --max-consensus-reads 1 --max-amplicon-size 1000"
        )

        let result = try await PBAAClusteringPipeline().run(request)

        XCTAssertEqual(result.referenceBundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.referenceBundleURL.path))
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
}
