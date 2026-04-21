import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class ManagedAssemblyArtifactTests: XCTestCase {
    func testManagedAssemblyResultRoundTripsThroughSidecar() throws {
        let tempDir = try makeTempDirectory(prefix: "managed-assembly-result")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
        let graphURL = tempDir.appendingPathComponent("assembly_graph.gfa")
        let logURL = tempDir.appendingPathComponent("assembly.log")
        try writeFASTA([("ctg1", "ACGTACGT"), ("ctg2", "GGGGTTTT")], to: contigsURL)
        try "H\tVN:Z:1.0\n".write(to: graphURL, atomically: true, encoding: .utf8)
        try "assembly completed\n".write(to: logURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: .megahit,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: graphURL,
            logPath: logURL,
            assemblerVersion: "1.2.9",
            commandLine: "megahit -1 R1.fastq.gz -2 R2.fastq.gz -o output",
            outputDirectory: tempDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 42.5
        )

        try result.save(to: tempDir)
        let loaded = try AssemblyResult.load(from: tempDir)

        XCTAssertEqual(loaded.tool, .megahit)
        XCTAssertEqual(loaded.readType, .illuminaShortReads)
        XCTAssertEqual(loaded.contigsPath, contigsURL)
        XCTAssertEqual(loaded.graphPath, graphURL)
        XCTAssertEqual(loaded.logPath, logURL)
        XCTAssertEqual(loaded.assemblerVersion, "1.2.9")
        XCTAssertEqual(loaded.outcome, .completed)
        XCTAssertEqual(loaded.statistics.contigCount, 2)
        XCTAssertEqual(loaded.statistics.totalLengthBP, 16)
    }

    func testManagedAssemblyResultRoundTripsCompletedWithNoContigsOutcome() throws {
        let tempDir = try makeTempDirectory(prefix: "managed-assembly-empty-result")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
        try "".write(to: contigsURL, atomically: true, encoding: .utf8)

        let result = AssemblyResult(
            tool: .hifiasm,
            readType: .pacBioHiFi,
            outcome: .completedWithNoContigs,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "0.25.0",
            commandLine: "hifiasm -o output sample.fastq.gz",
            outputDirectory: tempDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 12.0
        )

        try result.save(to: tempDir)
        let loaded = try AssemblyResult.load(from: tempDir)

        XCTAssertEqual(loaded.outcome, .completedWithNoContigs)
        XCTAssertEqual(loaded.statistics.contigCount, 0)
    }

    func testAssemblyResultLoadsLegacySpadesSidecar() throws {
        let tempDir = try makeTempDirectory(prefix: "legacy-spades-result")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contigsURL = tempDir.appendingPathComponent("contigs.fasta")
        let logURL = tempDir.appendingPathComponent("spades.log")
        try writeFASTA([("NODE_1", "ACTGACTGACTG")], to: contigsURL)
        try "spades completed\n".write(to: logURL, atomically: true, encoding: .utf8)

        let legacy = SPAdesAssemblyResult(
            contigsPath: contigsURL,
            scaffoldsPath: nil,
            graphPath: nil,
            logPath: logURL,
            paramsPath: nil,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            spadesVersion: "4.0.0",
            wallTimeSeconds: 90,
            commandLine: "spades.py --isolate -s reads.fastq.gz -o output",
            exitCode: 0
        )

        try legacy.save(to: tempDir)
        let loaded = try AssemblyResult.load(from: tempDir)

        XCTAssertEqual(loaded.tool, .spades)
        XCTAssertEqual(loaded.readType, .illuminaShortReads)
        XCTAssertEqual(loaded.contigsPath, contigsURL)
        XCTAssertEqual(loaded.logPath, logURL)
        XCTAssertEqual(loaded.assemblerVersion, "4.0.0")
        XCTAssertEqual(loaded.statistics.contigCount, 1)
    }

    func testLegacyProvenanceInfersAppleContainerBackend() throws {
        let payload = """
        {
          "assembler": "SPAdes",
          "assembler_version": "4.0.0",
          "container_image": "lungfish/spades:4.0.0-arm64",
          "container_runtime": "apple_containerization",
          "host_os": "macOS 26.0.0",
          "host_architecture": "arm64",
          "lungfish_version": "1.0.0",
          "assembly_date": "2026-04-19T18:00:00Z",
          "wall_time_seconds": 120.0,
          "command_line": "spades.py --isolate -o out",
          "parameters": {
            "mode": "isolate",
            "k_mer_sizes": "auto",
            "memory_gb": 16,
            "threads": 8,
            "skip_error_correction": false,
            "min_contig_length": 500
          },
          "inputs": [],
          "statistics": null
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(AssemblyProvenance.self, from: Data(payload.utf8))

        XCTAssertEqual(provenance.executionBackend, .appleContainerization)
        XCTAssertNil(provenance.managedEnvironment)
        XCTAssertEqual(provenance.containerRuntime, "apple_containerization")
    }

    func testNormalizeHifiasmOutputsGeneratesContigFASTA() throws {
        let tempDir = try makeTempDirectory(prefix: "hifiasm-normalizer")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .hifiasm,
            readType: .pacBioHiFi,
            inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
            projectName: "hifi-demo",
            outputDirectory: tempDir,
            threads: 12
        )

        let gfaURL = tempDir.appendingPathComponent("hifi-demo.bp.p_ctg.gfa")
        let gfa = """
        H\tVN:Z:1.0
        S\tptg000001l\tACGTACGTACGT
        S\tptg000002l\tGGGGAAAACCCC
        """
        try gfa.write(to: gfaURL, atomically: true, encoding: .utf8)

        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: tempDir,
            commandLine: "hifiasm -o hifi-demo sample.fastq.gz",
            wallTimeSeconds: 15
        )

        XCTAssertEqual(result.tool, AssemblyTool.hifiasm)
        XCTAssertEqual(result.readType, AssemblyReadType.pacBioHiFi)
        XCTAssertEqual(result.graphPath, gfaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.contigsPath.path))

        let fasta = try String(contentsOf: result.contigsPath, encoding: .utf8)
        XCTAssertTrue(fasta.contains(">ptg000001l"))
        XCTAssertTrue(fasta.contains(">ptg000002l"))
        XCTAssertEqual(result.statistics.contigCount, 2)
    }

    func testNormalizeHifiasmOutputsReturnsEmptyContigResult() throws {
        let tempDir = try makeTempDirectory(prefix: "hifiasm-empty-normalizer")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .hifiasm,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq.gz")],
            projectName: "ont-demo",
            outputDirectory: tempDir,
            threads: 8
        )

        let gfaURL = tempDir.appendingPathComponent("ont-demo.bp.p_ctg.gfa")
        try "".write(to: gfaURL, atomically: true, encoding: .utf8)

        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: tempDir,
            commandLine: "hifiasm --ont -o ont-demo sample.fastq.gz",
            wallTimeSeconds: 20
        )

        XCTAssertEqual(result.outcome, .completedWithNoContigs)
        XCTAssertEqual(result.graphPath, gfaURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.contigsPath.path))
        XCTAssertEqual(result.statistics.contigCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: result.contigsPath.appendingPathExtension("fai").path)
        )
    }

    func testAssembleCommandSourceIncludesEmptyContigCompletionBranch() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("LungfishCLI")
            .appendingPathComponent("Commands")
            .appendingPathComponent("AssembleCommand.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Assembly completed, but no contigs were generated."))
        XCTAssertTrue(source.contains(".completedWithNoContigs"))
    }

    func testManagedBundleBuilderCreatesReferenceBundleFromMegahitArtifacts() async throws {
        let tempDir = try makeTempDirectory(prefix: "managed-assembly-bundle")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputDir = tempDir.appendingPathComponent("megahit-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let contigsURL = outputDir.appendingPathComponent("final.contigs.fa")
        let logURL = outputDir.appendingPathComponent("assembly.log")
        try writeFASTA(
            [
                ("megahit_ctg_1", "ACGTACGTACGTACGT"),
                ("megahit_ctg_2", "TTTTCCCCAAAAGGGG"),
            ],
            to: contigsURL
        )
        try "megahit completed\n".write(to: logURL, atomically: true, encoding: .utf8)

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "megahit-demo",
            outputDirectory: outputDir,
            pairedEnd: true,
            threads: 8,
            minContigLength: 500,
            selectedProfileID: "meta-sensitive"
        )

        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: outputDir,
            commandLine: "megahit -1 R1.fastq.gz -2 R2.fastq.gz -o megahit-output",
            wallTimeSeconds: 18,
            assemblerVersion: "1.2.9"
        )
        let provenance = ProvenanceBuilder.build(
            request: request,
            result: result,
            inputRecords: []
        )

        let builder = AssemblyBundleBuilder()
        let bundleURL = try await builder.build(
            result: result,
            request: request,
            provenance: provenance,
            outputDirectory: tempDir,
            bundleName: "Managed Bundle"
        ) { _, _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("assembly/assembly.log").path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("assembly/provenance.json").path)
        )

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.name, "Managed Bundle")
        XCTAssertEqual(manifest.source.database, "MEGAHIT 1.2.9")

        let bundle = try await ReferenceBundle(url: bundleURL)
        XCTAssertEqual(bundle.chromosomeNames, ["megahit_ctg_1", "megahit_ctg_2"])
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFASTA(_ records: [(String, String)], to url: URL) throws {
        let body = records.map { name, sequence in
            ">\(name)\n\(sequence)\n"
        }.joined()
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
