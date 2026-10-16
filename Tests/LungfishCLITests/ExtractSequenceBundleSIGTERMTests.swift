// ExtractSequenceBundleSIGTERMTests.swift - A SIGTERM cancels extract sequence --bundle before it publishes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48 M2 (SWIFT SC4). The app's Cancel sends SIGTERM to the leaf and gives it
// `operationGrace`. The leaf turns the signal into a cancel of its build, publishes nothing, records
// the run as cancelled beside the bundle it would have published, exits 125 and leaves no process
// behind. The built lungfish-cli runs against a stand-in bgzip that writes its process ID and then
// sleeps, so the leaf is known to be at work when the signal arrives. The source bundle holds a plain
// FASTA with its index, so no real tool and no network are needed.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ExtractSequenceBundleSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "extract-sequence-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testABundleExtractionTurnsSIGTERMIntoACancelAndPublishesNothing() async throws {
        let source = try makeSourceBundle()
        let extractions = root.appendingPathComponent("Extractions", isDirectory: true)
        let output = extractions.appendingPathComponent("Region.lungfishref", isDirectory: true)
        let pidFile = root.appendingPathComponent("bgzip.pid")
        let condaRoot = try stubCondaRoot(pidFile: pidFile)

        let run = try CLISIGTERMHarness.launchCLI(
            ["extract", "sequence", source.path, "chr1:11-40", "--bundle", "--output", output.path, "--format", "json"],
            environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { run.stop() }
        let bgzipPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
            ProvenanceRecorder.loadEnvelope(from: extractions)?.status.rawValue
        })
        XCTAssertNotNil(bgzipPID, "the leaf never reached bgzip. Standard output: \(stop.standardOutput)")

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancelled run publishes no bundle")
        let left = try FileManager.default.contentsOfDirectory(atPath: extractions.path)
        XCTAssertEqual(left, [ProvenanceWriter.provenanceFilename], "only the cancelled record is left beside the bundle")
        let lines = stop.standardOutput.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.first?.contains("Extracting chr1:11-40") == true, "the row's first words. \(lines)")
        XCTAssertTrue(
            lines.last?.contains("Extraction cancelled. Nothing was published.") == true,
            "the last line is the failed event with the cancel's words. \(lines)"
        )
    }

    // MARK: - Fixture

    /// 60 bases of `chr1`, a plain FASTA with its index, so reading it needs no tool.
    private func makeSourceBundle() throws -> URL {
        let sequence = "ACGTTGCAACGGATCCATGCAAGCTTGACCTAGGTACCGAATTCGGCCATGGCATGCAAT"
        let bundle = root.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try ">chr1\n\(sequence)\n".write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t\(sequence.count)\t6\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            formatVersion: "1.0",
            name: "Source",
            identifier: "org.lungfish.tests.extract-sigterm",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [ChromosomeInfo(
                    name: "chr1", length: Int64(sequence.count), offset: 6,
                    lineBases: sequence.count, lineWidth: sequence.count + 1
                )]
            )
        ).save(to: bundle)
        return bundle
    }

    /// A conda root whose bgzip and samtools answer a version probe, and whose bgzip sleeps on any
    /// other call, after it wrote `$$`. The CLI reads the root from `LUNGFISH_CONDA_ROOT`, so the
    /// stand-ins win over any real tool whatever app identity the built CLI has.
    private func stubCondaRoot(pidFile: URL) throws -> URL {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bgzip = """
        #!/bin/sh
        case "$*" in
          *version*) echo "bgzip (htslib) 1.20"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec sleep 120
        """
        let samtools = """
        #!/bin/sh
        echo "samtools 1.20"
        exit 0
        """
        for (path, script) in [("envs/htslib/bin/bgzip", bgzip), ("envs/samtools/bin/samtools", samtools)] {
            let binary = condaRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return condaRoot
    }
}
