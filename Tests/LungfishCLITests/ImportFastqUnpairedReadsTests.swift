// ImportFastqUnpairedReadsTests.swift - import fastq reads an SRA run's three files as one sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// `fetch sra download` keeps a run's third file, the reads whose mate is
/// missing, and the window passes all three files to `import fastq`. Both
/// ways the command imports them as one bundle, the pairs as pairs and the
/// third file's reads as unpaired reads (finding F7-S1). Before, the third
/// file became a second sample of the same name and was skipped.
final class ImportFastqUnpairedReadsTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-fastq-unpaired")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testTheWindowsArgumentsForAThreeFileRunImportOneBundleOfEveryRead() async throws {
        let files = try writeRun("SRR9000005", pairedSpots: [1, 2, 4], unpairedSpots: [3])

        // The arguments `sraImportCLIArguments` builds for a run with no recipe.
        let command = try ImportCommand.FastqSubcommand.parse(files.map(\.path) + [
            "--project", project.path, "--platform", "illumina", "--pairing", "paired", "--format", "json",
            "--quality-binning", "none", "--compression", "balanced", "--no-optimize-storage",
        ])
        try await command.run()

        try assertOneBundleOfEveryRead("SRR9000005", pairs: 3, unpaired: 1)
    }

    func testTheFolderFetchSRADownloadWritesImportsOneBundleOfEveryRead() async throws {
        let files = try writeRun("SRR9000006", pairedSpots: [2, 3], unpairedSpots: [1, 4])

        let command = try ImportCommand.FastqSubcommand.parse([
            files[0].deletingLastPathComponent().path,
            "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage",
        ])
        try await command.run()

        try assertOneBundleOfEveryRead("SRR9000006", pairs: 2, unpaired: 2)
    }

    // MARK: - Helpers

    private func assertOneBundleOfEveryRead(_ run: String, pairs: Int, unpaired: Int) throws {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), ["\(run).lungfishfastq"])
        let bundle = imports.appendingPathComponent("\(run).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(
            try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 100).headers.count,
            pairs * 2 + unpaired
        )
        let classification = try XCTUnwrap(FASTQMetadataStore.load(for: fastq)?.readClassification)
        XCTAssertEqual(classification.pairedReadCount, pairs * 2)
        XCTAssertEqual(classification.unpairedReadCount, unpaired)
    }

    /// Writes one run as fasterq-dump names it into its own download folder.
    private func writeRun(_ run: String, pairedSpots: [Int], unpairedSpots: [Int]) throws -> [URL] {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ spots: [Int], bases: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let text = spots.map { "@\(run).\($0) \($0) length=8\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
        return [
            try write("\(run)_1.fastq", pairedSpots, bases: "ACGTACGT"),
            try write("\(run)_2.fastq", pairedSpots, bases: "TTGGCCAA"),
            try write("\(run).fastq", unpairedSpots, bases: "GATTACAG"),
        ]
    }
}
