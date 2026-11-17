// ViralReconFastpConfigTests.swift - The -c config that names fastp's adapters for a single-end Viral Recon sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-THREE-ROWS, items 8-11 (VIRALRECON-SE-ADAPTER-GUESS). The stand-in cases of
// ViralReconSingleEndAdaptersConformanceTests, which runs the real fastp. These need no tool.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ViralReconFastpConfigTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let folder = try TestTempDirectory.make(prefix: "viralrecon-fastp-config")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        root = folder.resolvingSymlinksInPath()
    }

    private func decision(_ name: String, paired: Bool) -> ViralReconReadPairingDecision {
        ViralReconReadPairingDecision(
            sampleName: name,
            sourceFASTQURLs: [URL(fileURLWithPath: "/reads/\(name).fastq.gz")],
            layout: paired ? .pairedFiles : .singleEnd,
            handling: paired ? .asPairs : .asSingle,
            reason: "test"
        )
    }

    private func write(_ decisions: [ViralReconReadPairingDecision], params: [String: String] = [:]) throws
        -> ViralReconFastpConfig.Written? {
        try ViralReconFastpConfig.writeIfNeeded(
            readPairing: decisions, params: params,
            launchFolder: root.appendingPathComponent("launch", isDirectory: true),
            stagingRoot: root.appendingPathComponent("launch/inputs", isDirectory: true)
        )
    }

    func testViralReconsOwnArgumentsAreKeptWordForWord() {
        // conf/modules_illumina.config:75 of nf-core/viralrecon at 395079f1d24dce731ac22e03d7a5e71f110103fc (3.0.0).
        XCTAssertEqual(
            ViralReconFastpConfig.viralReconArguments,
            "--cut_front --cut_tail --trim_poly_x --cut_mean_quality 30 --qualified_quality_phred 30 "
                + "--unqualified_percent_limit 10 --length_required 50"
        )
    }

    func testASingleEndSampleGetsViralReconsArgumentsAndTheNamedAdapters() throws {
        let written = try XCTUnwrap(try write([decision("S1", paired: false), decision("S2", paired: true)]))
        let bundled = try FastpPairedRunner.SingleReadAdapters.bundled()
        let folder = root.appendingPathComponent("launch/inputs/lungfish-fastp-adapters", isDirectory: true)
        let copy = folder.appendingPathComponent("fastp-known-adapters.fasta")

        XCTAssertEqual(written.configURL.path, root.appendingPathComponent("launch/lungfish-fastp-adapters.config").path)
        XCTAssertFalse(written.isFallback)
        XCTAssertEqual(written.adapters.fastaURL.path, copy.path, "the config names the run's copy")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: bundled.fastaURL), "the copy is the bundled list")
        XCTAssertEqual(written.adapters.fastaSequences, bundled.fastaSequences)
        XCTAssertEqual(written.adapters.adapterSequence, "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA")

        let single = ViralReconFastpConfig.viralReconArguments
            + " --adapter_sequence AGATCGGAAGAGCACACGTCTGAACTCCAGTCA --adapter_fasta \(copy.path)"
        XCTAssertEqual(ViralReconFastpConfig.singleEndArguments(adapters: written.adapters).joined(separator: " "), single)
        let text = try String(contentsOf: written.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("withName: 'FASTP' {"), "viralrecon's own selector, conf/modules_illumina.config:74")
        XCTAssertTrue(
            text.contains("ext.args = { meta.single_end ? '\(single)' : '\(ViralReconFastpConfig.viralReconArguments)' }"),
            text
        )
        XCTAssertTrue(
            text.contains("containerOptions = { meta.single_end ? '--volume \(folder.path):\(folder.path):ro' : '' }"),
            "the container of a single-end task sees the copy\n\(text)"
        )
    }

    func testARunWhoseSamplesAllRunPairedWritesNoConfig() throws {
        XCTAssertNil(try write([decision("S1", paired: true), decision("S2", paired: true)]))
        XCTAssertNil(try write([]), "a Nanopore run has no Illumina rows")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launch").path))
    }

    func testARunThatSkipsFastpWritesNoConfig() throws {
        XCTAssertNil(try write([decision("S1", paired: false)], params: ["skip_fastp": "true"]))
        XCTAssertNotNil(try write([decision("S1", paired: false)], params: ["skip_fastp": "false"]))
    }

    func testAMissingAdapterListRefusesTheRunInWords() {
        let refusal = FastpPairedRunError(
            "The list of known adapters that Lungfish trims from single reads is missing from this copy of Lungfish "
                + "(Tools/fastp-known-adapters.fasta). Install Lungfish again."
        )
        XCTAssertThrowsError(try ViralReconFastpConfig.writeIfNeeded(
            readPairing: [decision("S1", paired: false)], params: [:],
            launchFolder: root.appendingPathComponent("launch"), stagingRoot: root.appendingPathComponent("launch/inputs"),
            adapters: { throw refusal }
        )) { error in
            XCTAssertEqual(error as? FastpPairedRunError, refusal)
        }
        XCTAssertNoThrow(try ViralReconFastpConfig.writeIfNeeded(
            readPairing: [decision("S1", paired: true)], params: [:],
            launchFolder: root.appendingPathComponent("launch"), stagingRoot: root.appendingPathComponent("launch/inputs"),
            adapters: { throw refusal }
        ), "a paired run never reads the list")
    }

    func testAStagingRootTheConfigCannotNameMovesTheCopyToATempFolder() throws {
        let written = try XCTUnwrap(try ViralReconFastpConfig.writeIfNeeded(
            readPairing: [decision("S1", paired: false)], params: [:],
            launchFolder: root.appendingPathComponent("launch"),
            stagingRoot: root.appendingPathComponent("Dave's (run)/inputs", isDirectory: true)
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: written.adapterFolder) }
        XCTAssertTrue(written.isFallback)
        XCTAssertTrue(ViralReconFastpConfig.isSafe(written.adapterFolder.path), written.adapterFolder.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.adapters.fastaURL.path))
        XCTAssertFalse(try String(contentsOf: written.configURL, encoding: .utf8).contains("Dave's"))
    }
}
