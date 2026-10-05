// SRAWindowUnpairedReadsTests.swift - A run ENA lists as three files imports whole from the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// ENA lists some runs as three files, `<run>_1.fastq.gz` and
/// `<run>_2.fastq.gz` for the spots with both reads and `<run>.fastq.gz`
/// for the spots whose mate is missing. The window downloaded all three and
/// imported only the pair, and nothing recorded the third file (finding
/// F7-S1). The scripted mirror serves each file, so no test reaches the
/// network, and the import runs the shared code `lungfish-cli import fastq`
/// runs for the window's arguments.
final class SRAWindowUnpairedReadsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-window-unpaired")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAThreeFileRunImportsEveryReadWithItsRoleAndRecordsAllThreeFiles() async throws {
        let served = try servedRun("SRR9000003", pairedSpots: [1, 2, 3, 4, 6], unpairedSpots: [5, 7])
        let staged = try await stage("SRR9000003", served: served)
        defer { staged.removeFolder() }
        let names = ["SRR9000003_1.fastq.gz", "SRR9000003_2.fastq.gz", "SRR9000003.fastq.gz"]
        XCTAssertEqual(staged.reads.files.map(\.lastPathComponent), names)
        XCTAssertEqual(staged.download.enaSteps.count, 3)

        // The window hands all three files to `lungfish-cli import fastq`.
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let arguments = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: importConfiguration(staged.reads.files),
            r1: staged.reads.r1,
            r2: staged.reads.r2,
            unpaired: staged.reads.unpaired,
            projectDirectory: project
        )
        XCTAssertEqual(Array(arguments.prefix(5)), ["import", "fastq"] + staged.reads.files.map(\.path))
        XCTAssertEqual(Self.value(after: "--pairing", in: arguments), "paired")

        // The command reads the three as one sample and imports every read.
        let bundle = try await importAsTheCommandDoes(staged.reads.files, into: project)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers.count, 12)
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 10)
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 2)

        // The window's record names the three files and the reads each held.
        let run = try recordWindowProvenance(
            "SRR9000003", staged, bundle: bundle, fastq: fastq, metadata: metadata, arguments: arguments
        )
        XCTAssertEqual(
            run.parameters["stagingInputs"],
            .array(staged.reads.files.map { .string($0.standardizedFileURL.path) })
        )
        XCTAssertEqual(run.parameters["stagingInputReadCounts"], .dictionary([
            staged.reads.files[0].standardizedFileURL.path: .integer(5),
            staged.reads.files[1].standardizedFileURL.path: .integer(5),
            staged.reads.files[2].standardizedFileURL.path: .integer(2),
        ]))
        let interleave = try XCTUnwrap(run.steps.first { $0.toolName == "Lungfish Read-Set Interleave" })
        XCTAssertEqual(interleave.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, names)
    }

    func testATwoFileRunImportsAndRecordsAsBefore() async throws {
        let served = try servedRun("SRR9000002", pairedSpots: [1, 2, 3], unpairedSpots: [])
        let staged = try await stage("SRR9000002", served: served)
        defer { staged.removeFolder() }
        XCTAssertNil(staged.reads.unpaired)

        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let arguments = DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: importConfiguration(staged.reads.files),
            r1: staged.reads.r1,
            r2: staged.reads.r2,
            projectDirectory: project
        )
        XCTAssertEqual(Array(arguments.prefix(5)), ["import", "fastq"] + staged.reads.files.map(\.path) + ["--project"])

        let bundle = try await importAsTheCommandDoes(staged.reads.files, into: project)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertNil(metadata.readClassification)
        XCTAssertNil(staged.reads.readCounts(in: metadata.readClassification))

        let run = try recordWindowProvenance(
            "SRR9000002", staged, bundle: bundle, fastq: fastq, metadata: metadata, arguments: arguments
        )
        XCTAssertEqual(run.parameters["stagingInputs"], .array(staged.reads.files.map { .string($0.standardizedFileURL.path) }))
        XCTAssertNil(run.parameters["stagingInputReadCounts"], "a pair's record keeps the parameters it had")
    }

    // MARK: - Helpers

    /// One run's gzip files as ENA's mirror serves them, by file name.
    private func servedRun(_ run: String, pairedSpots: [Int], unpairedSpots: [Int]) throws -> [String: Data] {
        let folder = root.appendingPathComponent("mirror-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func gzip(_ name: String, _ spots: [Int], mate: Int?, bases: String) throws -> (String, Data) {
            let plain = folder.appendingPathComponent("\(name).plain")
            let suffix = mate.map { "/\($0)" } ?? "/1"
            let text = spots.map { "@\(run).\($0) \($0)\(suffix)\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: plain)
            let compressed = folder.appendingPathComponent(name)
            try KrakenOutputCompactor.gzipCopy(source: plain, destination: compressed)
            return (name, try Data(contentsOf: compressed))
        }
        var files = [
            try gzip("\(run)_1.fastq.gz", pairedSpots, mate: 1, bases: "ACGTACGT"),
            try gzip("\(run)_2.fastq.gz", pairedSpots, mate: 2, bases: "TTGGCCAA"),
        ]
        if !unpairedSpots.isEmpty {
            files.append(try gzip("\(run).fastq.gz", unpairedSpots, mate: nil, bases: "GATTACAG"))
        }
        return Dictionary(uniqueKeysWithValues: files)
    }

    /// Stages the run on ENA's route, as the window does, with the mirror
    /// serving `served` and ENA's record listing every served file.
    private func stage(_ run: String, served: [String: Data]) async throws -> SRAWindowStagedRun {
        let names = served.keys.sorted { lhs, rhs in
            // ENA lists the file without a suffix first.
            (lhs.contains("_") ? 1 : 0, lhs) < (rhs.contains("_") ? 1 : 0, rhs)
        }
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/SRR900/00\(run.suffix(1))/\(run)"
        let json = """
        {"run_accession": "\(run)", "library_layout": "PAIRED",
         "fastq_ftp": "\(names.map { "\(folder)/\($0)" }.joined(separator: ";"))",
         "fastq_bytes": "\(names.map { String(served[$0]!.count) }.joined(separator: ";"))"}
        """
        let record = try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
        return try await SRAWindowRunDownload.stage(
            accession: run,
            route: .enaMirror(record),
            in: root.appendingPathComponent("batch", isDirectory: true),
            mirrorFile: { url, _, _ in try XCTUnwrap(served[url.lastPathComponent]) },
            toolkit: { _, _ in
                XCTFail("ENA's mirror served every file, so the toolkit must not run")
                return []
            }
        )
    }

    private func importConfiguration(_ files: [URL]) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: files,
            detectedPlatform: .illumina,
            confirmedPlatform: .illumina,
            pairingMode: .pairedEnd,
            pairingModeIsUserChoice: false,
            qualityBinning: .none,
            skipClumpify: true,
            clumpingTool: .none,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: nil,
            compressionLevel: .fast
        )
    }

    /// Runs what `lungfish-cli import fastq <files> --pairing paired
    /// --no-optimize-storage` runs: the shared detection, then the import.
    private func importAsTheCommandDoes(_ files: [URL], into project: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let samples = FASTQBatchImporter.applyPairing(.paired, to: FASTQBatchImporter.detectPairs(from: files))
        XCTAssertEqual(samples.count, 1, "the run's files are one sample")
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: samples,
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: false,
                threads: 1,
                pairing: .paired
            )
        )
        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        XCTAssertEqual(result.skipped, 0)
        return FASTQBatchImporter.bundleOutputURL(for: samples[0], in: project)
    }

    private func recordWindowProvenance(
        _ accession: String,
        _ staged: SRAWindowStagedRun,
        bundle: URL,
        fastq: URL,
        metadata: PersistedFASTQMetadata,
        arguments: [String]
    ) throws -> WorkflowRun {
        try writeGUISRAFASTQImportProvenance(
            accession: accession,
            readRecord: nil,
            downloadSource: staged.download.source.rawValue,
            enaDownloadSteps: staged.download.enaSteps,
            toolkitDownloadTraces: [],
            cliArguments: arguments,
            cliStartedAt: Date(timeIntervalSince1970: 0),
            cliCompletedAt: Date(timeIntervalSince1970: 1),
            stagedFASTQFiles: staged.reads.files,
            stagedReadCounts: staged.reads.readCounts(in: metadata.readClassification),
            finalFASTQURL: fastq,
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast"
        )
        return try XCTUnwrap(ProvenanceRecorder.load(from: bundle))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
