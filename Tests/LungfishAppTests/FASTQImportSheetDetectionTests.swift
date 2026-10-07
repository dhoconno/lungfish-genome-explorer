// FASTQImportSheetDetectionTests.swift - The Import FASTQ sheet groups dropped files as lungfish-cli import fastq does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
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

        let sheetBundle = sheetProject.appendingPathComponent("Imports/SRR9.lungfishfastq", isDirectory: true)
        let cliBundle = cliProject.appendingPathComponent("Imports/SRR9.lungfishfastq", isDirectory: true)
        let sheetFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: sheetBundle))
        let cliFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: cliBundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: sheetFASTQ))
        let cliMetadata = try XCTUnwrap(FASTQMetadataStore.load(for: cliFASTQ))
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 6, "three pairs")
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 2, "and the run's two reads whose mate is missing")
        XCTAssertEqual(metadata.ingestion?.originalFilenames, files.map(\.lastPathComponent))

        // The same bundle. The files, every byte of the reads in their order,
        // the read counts and labels, and the command the provenance records
        // are the same. Only the sidecar's import date, a wall-clock time the
        // comparison's masks leave in a payload, differs.
        XCTAssertEqual(try Self.relativeFiles(in: sheetBundle), try Self.relativeFiles(in: cliBundle))
        let payload = try Self.decompressedBytes(of: sheetFASTQ)
        XCTAssertEqual(payload.split(separator: UInt8(ascii: "\n")).count, 32, "eight whole records")
        XCTAssertEqual(payload, try Self.decompressedBytes(of: cliFASTQ))
        XCTAssertEqual(metadata.readClassification, cliMetadata.readClassification)
        XCTAssertEqual(metadata.ingestion?.pairingMode, cliMetadata.ingestion?.pairingMode)
        XCTAssertEqual(metadata.ingestion?.pairingSource, cliMetadata.ingestion?.pairingSource)
        XCTAssertEqual(metadata.ingestion?.originalFilenames, cliMetadata.ingestion?.originalFilenames)
        XCTAssertEqual(
            try Self.recordedCommand(in: sheetBundle, project: sheetProject),
            try Self.recordedCommand(in: cliBundle, project: cliProject)
        )
    }

    func testASamplesImportCompletesEveryDroppedFileOfIt() throws {
        // File > Import tracks each dropped file and closes its request, and
        // its activity indicator, once every file has completed. The sheet
        // completed only R1 of a sample, so a pair, or a run's three files,
        // left the request open after the import ended.
        let files = try writeRun()
        let sample = try XCTUnwrap(groupFASTQByPairs(files).first)
        let tracker = SidebarImportRequestTracker(requestID: "drop", trackedURLs: files)

        var update: SidebarImportRequestTrackerUpdate?
        for url in MainSplitViewController.sidebarDropCompletionURLs(of: sample) {
            update = tracker.registerCompletion(requestID: "drop", completedURL: url, wasSuccessful: true)
        }

        XCTAssertEqual(update?.isFinished, true)
        XCTAssertEqual(update?.succeeded, 3)
    }

    // MARK: - A mate pairs only inside its own folder (review B-S1)

    func testTheSheetPairsTheMatesOfEveryFolderOfAScanInsideTheFolder() throws {
        // The Import Center flattens a recursive scan into one list, one
        // folder's files after the other's. Detection kept one file a stem,
        // the last one listed, so folder A's R1 paired with folder B's R2 and
        // the other two became single-end samples, where `import fastq
        // <folder> --recursive` pairs each folder alone.
        let delivery = root.appendingPathComponent("delivery", isDirectory: true)
        let a = try writeMates(in: delivery.appendingPathComponent("A", isDirectory: true))
        let b = try writeMates(in: delivery.appendingPathComponent("B", isDirectory: true))

        let sheet = groupFASTQByPairs(a + b)
        let recursive = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(delivery)

        XCTAssertEqual(sheet.map(\.sampleName), ["reads", "reads"])
        XCTAssertEqual(sheet.map(\.inputFiles), [a, b])
        XCTAssertEqual(
            sheet.map { $0.inputFiles.map(\.standardizedFileURL.path) },
            recursive.map { $0.inputFiles.map(\.standardizedFileURL.path) },
            "the sheet pairs the scan as the CLI's recursive scan does"
        )
    }

    func testARunsThirdFileJoinsOnlyThePairOfItsOwnFolder() {
        let files = [
            URL(fileURLWithPath: "/delivery/A/SRR1_1.fastq"),
            URL(fileURLWithPath: "/delivery/A/SRR1_2.fastq"),
            URL(fileURLWithPath: "/delivery/B/SRR1.fastq"),
        ]

        let sheet = groupFASTQByPairs(files)

        XCTAssertEqual(sheet.map(\.inputFiles), [Array(files.prefix(2)), [files[2]]])
        XCTAssertNil(sheet.first?.unpaired)
    }

    // MARK: - No sample of a sheet replaces another's bundle

    func testTheDuplicateDialogNeverOffersToReplaceABundleAnEarlierSampleOfTheSheetWrote() throws {
        // Two samples of one sheet can name one bundle, two files of one stem
        // from two folders of the Import Center's scan, for example. The sheet
        // runs `import fastq` once per sample, so the CLI cannot see that the
        // bundle is its own batch's, and the dialog offered Replace.
        XCTAssertEqual(
            MainSplitViewController.duplicateFileChoices(offeringReplace: true).map(\.title),
            ["Replace", "Keep Both", "Skip"]
        )
        XCTAssertEqual(
            MainSplitViewController.duplicateFileChoices(offeringReplace: false).map(\.title),
            ["Keep Both", "Skip"]
        )

        let imports = root.appendingPathComponent("P.lungfish/Imports", isDirectory: true)
        let written = imports.appendingPathComponent("S1.lungfishfastq", isDirectory: true)
        let older = imports.appendingPathComponent("S2.lungfishfastq", isDirectory: true)
        for bundle in [written, older] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }
        var batch = FASTQBatchImporter.BundlesWrittenByThisImport()
        batch.insert(written)
        XCTAssertTrue(batch.contains(written), "a bundle this batch wrote is never offered for Replace")
        XCTAssertFalse(batch.contains(older), "a bundle from an earlier import still is")
        let caseOnly = imports.appendingPathComponent("s1.lungfishfastq", isDirectory: true)
        if try imports.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            XCTAssertTrue(batch.contains(caseOnly), "the same bundle on a volume that ignores case")
        }
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

    private static func relativeFiles(in bundle: URL) throws -> [String] {
        let paths = FileManager.default.enumerator(atPath: bundle.path)?.allObjects as? [String] ?? []
        return paths.sorted()
    }

    /// The decompressed bytes of a plain or gzip FASTQ, every record whole.
    /// The comparison read the first 1,000 headers alone, so a difference
    /// of sequence, quality or a later read passed (review B-N5).
    private static func decompressedBytes(of fastq: URL) throws -> Data {
        var bytes = Data()
        try fastq.forEachChunkAutoDecompressing { bytes.append($0) }
        return bytes
    }

    /// The command the bundle's provenance records, with the project path
    /// written as `<PROJECT>`.
    private static func recordedCommand(in bundle: URL, project: URL) throws -> [String] {
        let url = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let data = PortablePath.resolveJSON(try Data(contentsOf: url), forFileAt: url)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        XCTAssertFalse(envelope.argv.isEmpty)
        let spellings = Set([project.path, project.standardizedFileURL.path, project.resolvingSymlinksInPath().path])
            .sorted { $0.count > $1.count }
        return envelope.argv.map { argument in
            spellings.reduce(argument) { $0.replacingOccurrences(of: $1, with: "<PROJECT>") }
        }
    }

    /// `reads_R1.fastq` and `reads_R2.fastq`, one pair of mates, in `folder`.
    private func writeMates(in folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try [1, 2].map { mate in
            let url = folder.appendingPathComponent("reads_R\(mate).fastq")
            try Data("@\(folder.lastPathComponent).1/\(mate)\nACGTACGT\n+\nIIIIIIII\n".utf8).write(to: url)
            return url
        }
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
