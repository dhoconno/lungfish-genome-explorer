// ClassificationReadFormatWizardTests.swift - Wizard read plans and GUI/CLI parity for Kraken2 read format
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
@testable import LungfishWorkflow

/// The Kraken2 wizard used to treat every single-file sample, including a
/// `.lungfishfastq` bundle with interleaved pairing, as single-end. It now
/// classifies the layout the way the EsViritu wizard does and the recorded
/// CLI command reproduces the decision.
final class ClassificationReadFormatWizardTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeFASTQ(_ headers: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-classification-wizard-\(UUID().uuidString)", isDirectory: true)
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

    private func makeDatabase(path: URL) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: "Viral",
            tool: "kraken2",
            version: "2026.1",
            sizeBytes: 1,
            catalogID: "kraken2-viral",
            installationRecipe: nil,
            payloadDigest: "sha256:viral-fixture",
            description: "Viral fixture",
            path: path,
            status: .ready,
            recommendedRAM: 1
        )
    }

    // MARK: - Read plans

    func testSeparateR1R2FilesArePairedWithoutScanning() {
        let sample = MetagenomicsSampleInput(
            sampleId: "s",
            fastq1: URL(fileURLWithPath: "/x/s_R1.fastq"),
            fastq2: URL(fileURLWithPath: "/x/s_R2.fastq")
        )
        let plan = ClassificationSampleReadPlan.plan(for: sample) { _ in
            XCTFail("separate pairs must not be scanned")
            return self.layout(.singleEnd)
        }
        XCTAssertEqual(plan.format, .paired)
        XCTAssertEqual(plan.shortLabel, "PE")
    }

    func testInterleavedBundleRunsAsPairs() {
        let sample = MetagenomicsSampleInput(sampleId: "s", fastq1: URL(fileURLWithPath: "/x/s.lungfishfastq"), fastq2: nil)
        let plan = ClassificationSampleReadPlan.plan(for: sample) { _ in self.layout(.strictlyInterleaved) }
        XCTAssertEqual(plan.format, .interleaved)
        XCTAssertEqual(plan.label, "Interleaved paired-end reads")
        XCTAssertEqual(plan.shortLabel, "interleaved PE")
    }

    func testMixedBundleRunsSingleEnd() {
        let sample = MetagenomicsSampleInput(sampleId: "s", fastq1: URL(fileURLWithPath: "/x/s.lungfishfastq"), fastq2: nil)
        let plan = ClassificationSampleReadPlan.plan(for: sample) { _ in self.layout(.mixedInterleaved) }
        XCTAssertEqual(plan.format, .unpaired)
        XCTAssertEqual(plan.label, "Mixed paired and merged reads (run as single-end)")
        XCTAssertEqual(plan.shortLabel, "mixed, run as SE")
    }

    func testRealInterleavedFileIsClassifiedByDefault() throws {
        let url = try makeFASTQ(["a 1:N:0:1", "a 2:N:0:1", "b 1:N:0:1", "b 2:N:0:1"])
        let samples = MetagenomicsSampleGrouper.group([url])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(ClassificationSampleReadPlan.plan(for: samples[0]).format, .interleaved)
    }

    // MARK: - Config and recorded CLI command

    func testProfileConfigCarriesTheInterleavedPlanAndRoundTripsThroughTheCLI() throws {
        let url = try makeFASTQ(["a/1", "a/2", "b/1", "b/2"])
        let sample = MetagenomicsSampleInput(sampleId: "s", fastq1: url, fastq2: nil)
        let databasePath = url.deletingLastPathComponent().appendingPathComponent("db", isDirectory: true)
        let outputDirectory = url.deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)
        let plan = ClassificationSampleReadPlan.plan(for: sample)
        XCTAssertEqual(plan.format, .interleaved)

        let guiConfig = ClassificationWizardSheet.makeProfileConfig(
            sample: sample,
            readPlan: plan,
            database: makeDatabase(path: databasePath),
            databasePath: databasePath,
            outputDirectory: outputDirectory,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: false,
            extraArguments: []
        )
        XCTAssertEqual(guiConfig.readFormat, .interleaved)
        XCTAssertTrue(guiConfig.interleavedInput)
        XCTAssertFalse(guiConfig.isPairedEnd)
        XCTAssertEqual(guiConfig.inputLayout?.layout, .strictlyInterleaved)

        let invocation = ClassificationCLIInvocationBuilder.build(for: guiConfig)
        XCTAssertTrue(invocation.arguments.contains("--read-format"))
        let command = try ClassifyCommand.parse(Array(invocation.arguments.dropFirst(2)))
        let cliConfig = try command.makeConfigForTesting(
            inputURLs: [url],
            databasePath: databasePath,
            inputFormat: .fastq,
            outputDirectory: outputDirectory
        )
        XCTAssertEqual(cliConfig.readFormat, guiConfig.readFormat)
        XCTAssertEqual(cliConfig.kraken2Arguments(), guiConfig.kraken2Arguments())
    }

    func testProfileConfigWithoutAPlanKeepsTheOldDefaults() throws {
        let url = try makeFASTQ(["a/1", "a/2"])
        let databasePath = url.deletingLastPathComponent()
        let single = ClassificationWizardSheet.makeProfileConfig(
            sample: MetagenomicsSampleInput(sampleId: "s", fastq1: url, fastq2: nil),
            database: makeDatabase(path: databasePath),
            databasePath: databasePath,
            outputDirectory: databasePath,
            confidence: 0.2, minimumHitGroups: 2, threads: 4, memoryMapping: false, extraArguments: []
        )
        XCTAssertEqual(single.readFormat, .unpaired)

        let paired = ClassificationWizardSheet.makeProfileConfig(
            sample: MetagenomicsSampleInput(sampleId: "s", fastq1: url, fastq2: url),
            database: makeDatabase(path: databasePath),
            databasePath: databasePath,
            outputDirectory: databasePath,
            confidence: 0.2, minimumHitGroups: 2, threads: 4, memoryMapping: false, extraArguments: []
        )
        XCTAssertEqual(paired.readFormat, .paired)
    }
}
