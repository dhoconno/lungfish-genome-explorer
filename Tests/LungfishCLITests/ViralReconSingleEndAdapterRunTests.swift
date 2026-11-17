// ViralReconSingleEndAdapterRunTests.swift - A single-end Viral Recon run names fastp's adapters in its launch and record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-THREE-ROWS, items 8-11 (VIRALRECON-SE-ADAPTER-GUESS). `workflow run nf-core/viralrecon` runs in process on
// a runner that keeps the launch and the text of each `-c` file, since the launch folder goes when the run ends.

import Foundation
import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ViralReconSingleEndAdapterRunTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-se-adapter-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Keeps each launch, the text of its `-c` files and whether the adapter FASTA each names exists at launch.
    final class ConfigKeepingRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        private(set) var launches: [NFCoreWorkflowLaunch] = []
        private(set) var configs: [String: String] = [:]

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            launches.append(launch)
            for (index, word) in launch.arguments.enumerated() where word == "-c" && index + 1 < launch.arguments.count {
                let path = launch.arguments[index + 1]
                configs[URL(fileURLWithPath: path).lastPathComponent] = try String(contentsOfFile: path, encoding: .utf8)
            }
            if let index = launch.arguments.firstIndex(of: "--outdir"), index + 1 < launch.arguments.count {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: launch.arguments[index + 1]), withIntermediateDirectories: true)
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }
    }

    /// One Illumina amplicon sample of single reads, run as `ViralReconLaunchedRun` runs its paired one.
    private func runSingleEnd(using runner: ConfigKeepingRunner) async throws -> URL {
        let reads = root.appendingPathComponent("reads/S1.fastq")
        try FileManager.default.createDirectory(at: reads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@a\nACGT\n+\nIIII\n@b\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let primerBED = root.appendingPathComponent("primers/primers.bed")
        try FileManager.default.createDirectory(at: primerBED.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "MN908947.3\t30\t54\tnCoV-2019_1_LEFT\t1\t+\n".write(to: primerBED, atomically: true, encoding: .utf8)
        let samplesheet = root.appendingPathComponent("samplesheet.csv")
        try "sample,fastq_1,fastq_2\nS1,\(reads.path),\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        try await RunSubcommand.parse([
            "nf-core/viralrecon", "--executor", "docker", "--input", samplesheet.path,
            "--results-dir", root.appendingPathComponent("results").path,
            "--expected-output", root.appendingPathComponent("results").path, "--bundle-path", bundle.path,
            "--param", "platform=illumina", "--param", "protocol=amplicon", "--param", "genome=MN908947.3",
            "--param", "primer_bed=\(primerBED.path)", "--param", "max_cpus=2", "--param", "max_memory=4.GB",
            "--version", "3.0.0", "--quiet",
        ]).run(nfCoreRunner: runner)
        return bundle
    }

    func testASingleEndRunNamesTheAdaptersInItsLaunchAndItsRecord() async throws {
        let runner = ConfigKeepingRunner()
        let bundle = try await runSingleEnd(using: runner)
        let launch = try XCTUnwrap(runner.launches.first, "the run launched nothing")
        let configs = launch.arguments.indices.filter { launch.arguments[$0] == "-c" }.map {
            URL(fileURLWithPath: launch.arguments[$0 + 1]).lastPathComponent
        }
        XCTAssertEqual(configs, ["lungfish-resource-limits.config", "lungfish-fastp-adapters.config"])
        XCTAssertLessThan(try XCTUnwrap(launch.arguments.lastIndex(of: "-c")), try XCTUnwrap(launch.arguments.firstIndex(of: "run")))

        let text = try XCTUnwrap(runner.configs["lungfish-fastp-adapters.config"])
        XCTAssertTrue(text.contains("withName: 'FASTP' {"), text)
        XCTAssertTrue(text.contains("--adapter_sequence AGATCGGAAGAGCACACGTCTGAACTCCAGTCA --adapter_fasta /"), text)
        XCTAssertTrue(text.contains("/inputs/lungfish-fastp-adapters/fastp-known-adapters.fasta"), "the run's own copy\n\(text)")

        let manifest = try NFCoreRunBundleStore.read(from: bundle)
        XCTAssertTrue(manifest.commandPreview.contains("lungfish-fastp-adapters.config"), manifest.commandPreview)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundle))
        let recorded = try XCTUnwrap(try envelope.legacyWorkflowRun().parameters["singleReadAdapters"], "BIO 4")
        let bundled = try FastpPairedRunner.SingleReadAdapters.bundled()
        XCTAssertEqual(recorded, try FastpPairedRunner.SingleReadAdapters(fastaURL: bundled.fastaURL).provenanceValue,
                       "the record names the adapters and the FASTA by file name")
    }

    func testAPairedRunLaunchesAndRecordsAsBefore() async throws {
        let run = try await ViralReconLaunchedRun.run(in: root)
        let launch = try XCTUnwrap(run.runner.launches.first, "the run launched nothing")
        XCTAssertEqual(launch.arguments.filter { $0 == "-c" }.count, 1, "only the resource-limit config")
        XCTAssertFalse(launch.arguments.contains { $0.hasSuffix("lungfish-fastp-adapters.config") })
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: run.bundle))
        XCTAssertNil(try envelope.legacyWorkflowRun().parameters["singleReadAdapters"])
    }
}
