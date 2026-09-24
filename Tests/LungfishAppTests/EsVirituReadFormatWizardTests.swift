// EsVirituReadFormatWizardTests.swift - Wizard read plans and GUI/CLI parity for EsViritu read format (NEW-06)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
@testable import LungfishWorkflow

final class EsVirituReadFormatWizardTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeFASTQ(_ headers: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-esviritu-wizard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("reads.fastq")
        try headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func layout(_ kind: FASTQReadLayout) -> FASTQReadLayoutClassification {
        FASTQReadLayoutClassification(
            layout: kind, scannedRecords: 4, matePairs: 1, unpairedRecords: 2,
            scannedWholeFile: true, metadata: FASTQPairingMetadataHints(), reason: "test"
        )
    }

    // MARK: - Read plan labels

    func testSeparateR1R2FilesArePaired() {
        let sample = MetagenomicsSampleInput(
            sampleId: "s",
            fastq1: URL(fileURLWithPath: "/x/s_R1.fastq"),
            fastq2: URL(fileURLWithPath: "/x/s_R2.fastq")
        )
        let plan = EsVirituSampleReadPlan.plan(for: sample) { _ in
            XCTFail("separate pairs must not be scanned")
            return self.layout(.singleEnd)
        }
        XCTAssertEqual(plan.format, .paired)
        XCTAssertEqual(plan.label, "Paired-end reads")
    }

    func testInterleavedBundleIsLabelledInterleaved() {
        let sample = MetagenomicsSampleInput(sampleId: "s", fastq1: URL(fileURLWithPath: "/x/s.lungfishfastq"), fastq2: nil)
        let plan = EsVirituSampleReadPlan.plan(for: sample) { _ in self.layout(.strictlyInterleaved) }
        XCTAssertEqual(plan.format, .interleaved)
        XCTAssertEqual(plan.label, "Interleaved paired-end reads")
    }

    func testMixedBundleIsLabelledMixedAndRunsUnpaired() {
        let sample = MetagenomicsSampleInput(sampleId: "s", fastq1: URL(fileURLWithPath: "/x/s.lungfishfastq"), fastq2: nil)
        let plan = EsVirituSampleReadPlan.plan(for: sample) { _ in self.layout(.mixedInterleaved) }
        XCTAssertEqual(plan.format, .unpaired)
        XCTAssertEqual(plan.label, "Mixed paired and merged reads (run as single-end)")
        XCTAssertEqual(plan.layout?.layout, .mixedInterleaved)
    }

    func testSingleEndStaysSingleEnd() {
        let sample = MetagenomicsSampleInput(sampleId: "s", fastq1: URL(fileURLWithPath: "/x/s.fastq"), fastq2: nil)
        let plan = EsVirituSampleReadPlan.plan(for: sample) { _ in self.layout(.singleEnd) }
        XCTAssertEqual(plan.format, .unpaired)
        XCTAssertEqual(plan.label, "Single-end reads")
    }

    func testRealInterleavedFileIsClassifiedByDefault() throws {
        let url = try makeFASTQ(["a 1:N:0:1", "a 2:N:0:1", "b 1:N:0:1", "b 2:N:0:1"])
        let samples = MetagenomicsSampleGrouper.group([url])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(EsVirituSampleReadPlan.plan(for: samples[0]).format, .interleaved)
    }

    func testReadinessWaitsForReadLayouts() {
        XCTAssertFalse(EsVirituRunReadiness.canRun(
            groupedSampleCount: 1,
            isBatchMode: false,
            sampleName: "s",
            isDatabaseInstalled: true,
            databasePath: URL(fileURLWithPath: "/tmp/db"),
            readLayoutsReady: false
        ))
    }

    // MARK: - Recorded CLI command reproduces the GUI decision

    func testRecordedCLICommandCarriesReadFormatAndRoundTrips() throws {
        let url = try makeFASTQ(["a/1", "a/2", "b/1", "b/2"])
        let guiConfig = EsVirituConfig(
            inputFiles: [url],
            isPairedEnd: false,
            sampleName: "s",
            outputDirectory: URL(fileURLWithPath: "/tmp/esv-out"),
            databasePath: URL(fileURLWithPath: "/tmp/esv-db"),
            readFormat: .interleaved
        )
        let args = AppDelegate.esVirituDetectCLIArguments(for: guiConfig)
        XCTAssertEqual(Array(args.suffix(2)), ["--read-format", "interleaved"])

        let command = try EsVirituCommand.DetectSubcommand.parse(["detect"] + args)
        let cliConfig = try command.makeConfigForTesting(
            databaseURL: guiConfig.databasePath,
            outputDirectory: guiConfig.outputDirectory
        )
        XCTAssertEqual(cliConfig.readFormat, guiConfig.readFormat)
        XCTAssertEqual(cliConfig.esVirituArguments(), guiConfig.esVirituArguments())
    }

    func testRecordedCLICommandForMixedInputRunsUnpaired() throws {
        let url = try makeFASTQ(["a/1", "a/2", "b/1", "b/2"])
        let guiConfig = EsVirituConfig(
            inputFiles: [url],
            isPairedEnd: false,
            sampleName: "s",
            outputDirectory: URL(fileURLWithPath: "/tmp/esv-out"),
            databasePath: URL(fileURLWithPath: "/tmp/esv-db"),
            readFormat: .unpaired
        )
        let command = try EsVirituCommand.DetectSubcommand.parse(
            ["detect"] + AppDelegate.esVirituDetectCLIArguments(for: guiConfig)
        )
        let cliConfig = try command.makeConfigForTesting(
            databaseURL: guiConfig.databasePath,
            outputDirectory: guiConfig.outputDirectory
        )
        // Explicit --read-format unpaired is not overridden by auto-detection.
        XCTAssertEqual(cliConfig.readFormat, .unpaired)
    }
}
