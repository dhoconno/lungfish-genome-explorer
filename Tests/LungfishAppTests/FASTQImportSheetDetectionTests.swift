// FASTQImportSheetDetectionTests.swift - The Import FASTQ sheet groups dropped files as lungfish-cli import fastq does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

/// The Import FASTQ sheet paired dropped files with rules of its own and ran
/// `lungfish-cli import fastq` once per pair. A run's three files, `<run>_1`,
/// `<run>_2` and `<run>.fastq`, became the pair and a second sample of the
/// run's name, so the reads whose mate is missing never joined the pair
/// (f9-report.md, concern 3), and a lone file named like one mate took a
/// name the CLI never gives it. The sheet now groups files with
/// `FASTQBatchImporter.detectPairs(from:)`, the detection the CLI runs, and
/// imports each sample's files in one CLI run, so for the same files the
/// sheet and the CLI make the same samples, bundles, read counts and
/// recorded command.
final class FASTQImportSheetDetectionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-sheet-detection")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testTheSheetGroupsARunsThreeFilesAsOneSampleAsTheCLIDoes() throws {
        let files = try writeRun()

        let sheet = groupFASTQByPairs(files)
        let cli = FASTQBatchImporter.detectPairs(from: files)

        XCTAssertEqual(sheet.map(\.sampleName), ["SRR9"])
        XCTAssertEqual(sheet.map(\.sampleName), cli.map(\.sampleName))
        XCTAssertEqual(sheet.map(\.inputFiles), cli.map(\.inputFiles))
        XCTAssertEqual(sheet.first?.unpaired, files[2])
        let arguments = FASTQIngestionService.cliImportArguments(
            pair: try XCTUnwrap(sheet.first),
            projectDirectory: root.appendingPathComponent("P.lungfish"),
            importConfig: Self.untouchedSheet(files: files),
            bundleName: "SRR9"
        )
        XCTAssertEqual(Array(arguments.prefix(5)), ["import", "fastq"] + files.map(\.path), "one CLI run names all three files")
    }

    func testTheSheetNamesEverySampleAsTheCLIDoes() {
        let files = [
            "pairA_R1_001.fastq.gz", "pairA_R2_001.fastq.gz", "lone_1.fastq", "lone_R1_001.fastq.gz", "dots.1.fq",
            "plain.fastq", "reads.bam", "SRR5_1.fq.gz", "SRR5_2.fq.gz", "SRR5.fastq.gz",
        ].map { URL(fileURLWithPath: "/reads").appendingPathComponent($0) }

        let sheet = groupFASTQByPairs(files)
        let cli = FASTQBatchImporter.detectPairs(from: files)

        XCTAssertEqual(sheet.map(\.sampleName), cli.map(\.sampleName))
        XCTAssertEqual(sheet.map(\.inputFiles), cli.map(\.inputFiles))
        XCTAssertEqual(
            sheet.map(\.sampleName).sorted(),
            ["SRR5", "dots.1", "lone_1", "lone_R1_001", "pairA", "plain", "reads"]
        )
    }

    func testTheSheetsPairingChoiceSplitsARunsThreeFilesAsTheCLIDoes() throws {
        let files = try writeRun()
        let sheet = groupFASTQByPairs(files)
        for (mode, pairing) in [
            (FASTQIngestionConfig.PairingMode.singleEnd, FASTQBatchImporter.ImportPairing.single),
            (.interleaved, .interleaved),
        ] {
            let split = FASTQFilePair.applying(pairingMode: mode, to: sheet)
            let cli = FASTQBatchImporter.applyPairing(pairing, to: FASTQBatchImporter.detectPairs(from: files))
            XCTAssertEqual(split.map(\.sampleName), cli.map(\.sampleName), "\(mode)")
            XCTAssertEqual(split.map(\.inputFiles), cli.map(\.inputFiles), "\(mode)")
            XCTAssertTrue(split.allSatisfy { $0.r2 == nil && $0.unpaired == nil }, "\(mode)")
        }
        XCTAssertEqual(FASTQFilePair.applying(pairingMode: .pairedEnd, to: sheet).map(\.inputFiles), sheet.map(\.inputFiles))
    }

    func testTheSheetsImportOfARunsThreeFilesMakesTheBundleTheCLIMakes() async throws {
        let files = try writeRun()
        let sheetProject = root.appendingPathComponent("Sheet.lungfish", isDirectory: true)
        let cliProject = root.appendingPathComponent("CLI.lungfish", isDirectory: true)
        for project in [sheetProject, cliProject] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }

        // Every sample the sheet makes of the files, through the CLI command
        // the sheet runs for it, in order.
        for sample in groupFASTQByPairs(files) {
            let arguments = FASTQIngestionService.cliImportArguments(
                pair: sample,
                projectDirectory: sheetProject,
                importConfig: Self.untouchedSheet(files: files),
                bundleName: sample.sampleName
            )
            try await RecordedCLICommand.runInProcess(CLIImportRunner.commandLine(arguments: arguments))
        }
        // The same files through the CLI as a user would type it.
        try await RecordedCLICommand.runInProcess(
            CLIImportRunner.commandLine(arguments: ["import", "fastq"] + files.map(\.path) + [
                "--project", cliProject.path, "--platform", "auto", "--quality-binning", "none",
                "--compression", "balanced", "--no-optimize-storage",
            ])
        )

        let bundle = sheetProject.appendingPathComponent("Imports/SRR9.lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 6, "three pairs")
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 2, "and the run's two reads whose mate is missing")
        XCTAssertEqual(metadata.ingestion?.originalFilenames, files.map(\.lastPathComponent))
        OutputEquivalence.assertSame(sheetProject, cliProject, kind: .bundle)
    }

    // MARK: - Helpers

    /// The sheet's settings when the user changes nothing but storage and
    /// quality binning, which are off.
    private static func untouchedSheet(files: [URL]) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: files,
            detectedPlatform: .unknown,
            confirmedPlatform: .unknown,
            platformIsUserChoice: false,
            pairingMode: .pairedEnd,
            pairingModeIsUserChoice: false,
            qualityBinning: .none,
            skipClumpify: true,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: nil,
            compressionLevel: .balanced
        )
    }

    /// One run as fasterq-dump names it. Three spots hold both reads and two
    /// hold one.
    private func writeRun() throws -> [URL] {
        let folder = root.appendingPathComponent("download-SRR9", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ spots: [Int], bases: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let text = spots.map { "@SRR9.\($0) \($0) length=8\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
        return [
            try write("SRR9_1.fastq", [1, 2, 4], bases: "ACGTACGT"),
            try write("SRR9_2.fastq", [1, 2, 4], bases: "TTGGCCAA"),
            try write("SRR9.fastq", [3, 5], bases: "GATTACAG"),
        ]
    }
}
