// ViralReconResultsFolderPinTests.swift - What the results folder check of a Viral Recon run must leave alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.21 STALE-OUT, M1. These pass at the base, before any check on the results folder exists, and
// they must keep passing after it. A results folder that does not exist yet or that is empty builds the request it
// always built, with the same parameters and the same arguments.

import XCTest
@testable import LungfishWorkflow

final class ViralReconResultsFolderPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viral-recon-results-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAMissingResultsFolderBuildsTheSameRequest() throws {
        let output = root.appendingPathComponent("viralrecon-results-a1b2c3d4", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let request = try Self.makeRequest(outputDirectory: output)

        Self.assertUnchanged(request, output: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "building a request creates nothing")
    }

    func testAnEmptyResultsFolderBuildsTheSameRequest() throws {
        let output = root.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let request = try Self.makeRequest(outputDirectory: output)

        Self.assertUnchanged(request, output: output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    /// The wizard's layout. Its staging folder, full of the staged inputs, sits beside the results folder and not in
    /// it, so the results folder is still new.
    func testTheWizardsStagingFolderBesideTheResultsFolderDoesNotCount() throws {
        let staging = root.appendingPathComponent(".viralrecon-inputs-a1b2c3d4", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "sample,fastq_1,fastq_2\n".write(
            to: staging.appendingPathComponent("samplesheet.csv"),
            atomically: true,
            encoding: .utf8
        )
        let output = root.appendingPathComponent("viralrecon-results-a1b2c3d4", isDirectory: true)

        let request = try Self.makeRequest(outputDirectory: output)

        Self.assertUnchanged(request, output: output)
    }

    static func assertUnchanged(
        _ request: ViralReconRunRequest,
        output: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bundle = URL(fileURLWithPath: "/tmp/run/viralrecon.lungfishrun")
        XCTAssertEqual(request.outputDirectory, output, file: file, line: line)
        XCTAssertEqual(request.effectiveParams["outdir"], output.path, file: file, line: line)
        XCTAssertEqual(request.effectiveParams["input"], request.samplesheetURL.path, file: file, line: line)

        let args = request.cliArguments(bundlePath: bundle)
        let leading = [
            "workflow", "run", "nf-core/viralrecon",
            "--executor", request.executor.rawValue,
            "--results-dir", output.path,
            "--bundle-path", bundle.path,
            "--version", request.version,
            "--input", request.samplesheetURL.path,
            "--expected-output", output.path,
        ]
        XCTAssertEqual(Array(args.prefix(leading.count)), leading, file: file, line: line)
        XCTAssertEqual(args.filter { $0 == "--results-dir" }.count, 1, file: file, line: line)
        XCTAssertFalse(args.contains("outdir=\(output.path)"), file: file, line: line)
        XCTAssertFalse(args.contains("--prepare-only"), file: file, line: line)
    }

    static func makeRequest(outputDirectory: URL) throws -> ViralReconRunRequest {
        try ViralReconRunRequest(
            samples: [
                ViralReconSample(
                    sampleName: "SARS2_A",
                    sourceBundleURL: URL(fileURLWithPath: "/tmp/A.lungfishfastq"),
                    fastqURLs: [
                        URL(fileURLWithPath: "/tmp/A_R1.fastq.gz"),
                        URL(fileURLWithPath: "/tmp/A_R2.fastq.gz"),
                    ],
                    barcode: nil,
                    sequencingSummaryURL: nil
                ),
            ],
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: URL(fileURLWithPath: "/tmp/run/inputs/samplesheet.csv"),
            outputDirectory: outputDirectory,
            executor: .docker,
            version: "3.0.0",
            reference: .genome("MN908947.3"),
            primer: ViralReconPrimerSelection(
                bundleURL: URL(fileURLWithPath: "/tmp/QIASeqDIRECT-SARS2.lungfishprimers"),
                displayName: "QIASeq DIRECT SARS-CoV-2",
                bedURL: URL(fileURLWithPath: "/tmp/primers.bed"),
                fastaURL: URL(fileURLWithPath: "/tmp/primers.fasta"),
                leftSuffix: "_LEFT",
                rightSuffix: "_RIGHT",
                derivedFasta: true
            ),
            minimumMappedReads: 1000,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: [.assembly, .kraken2],
            advancedParams: ["max_cpus": "4", "max_memory": "8.GB"]
        )
    }
}
