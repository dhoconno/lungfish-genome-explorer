// FASTQPairedRootTests.swift - A bundle root of R1 and R2 files resolves and exports both mates (Phase 3.3 lane PAIREDROOT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// `lungfish-cli extract reads --by-id --source R1 --source R2 --bundle` writes a `.lungfishfastq` root that holds an `_R1`
/// and an `_R2` file with no `source-files.json` and no derived manifest. For such a root the resolver returned the first
/// file only, so the dashboard card described R1 alone and an export wrote R1 and dropped R2 with no word (BIO-PAIRED-ROOT-
/// PRIMARY, S1). A root that no manifest describes now resolves to every FASTQ it holds. A single-file root, a derived
/// bundle and a root with a source manifest keep the answers they had.
final class FASTQPairedRootTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("paired-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Four reads of one sequence at one quality.
    private func reads(_ prefix: String, sequence: String, quality: Character) -> String {
        (1...4).map { "@\(prefix)\($0)\n\(sequence)\n+\n\(String(repeating: quality, count: sequence.count))\n" }.joined()
    }

    /// A root with the named files, each holding the given text, and nothing else.
    private func makeRoot(named name: String = "pair-extract", files: [(name: String, text: String)]) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for file in files {
            try file.text.write(to: bundle.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }
        return bundle
    }

    /// The item 8 fixture of the ruling: R1 four reads at Q40 with GC 50%, R2 four reads at Q10 with GC 100%.
    private func makePairedRoot() throws -> URL {
        try makeRoot(files: [
            ("s_R1.fastq", reads("r1_", sequence: "ACGT", quality: "I")),
            ("s_R2.fastq", reads("r2_", sequence: "GGCC", quality: "+")),
        ])
    }

    func testRootWithR1AndR2FilesResolvesBothMates() throws {
        let bundle = try makePairedRoot()

        let resolved = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: bundle))

        XCTAssertEqual(resolved.map(\.lastPathComponent), ["s_R1.fastq", "s_R2.fastq"], "R1 first, then R2")
        XCTAssertFalse(FASTQBundle.isMultiFileBundle(bundle), "isMultiFileBundle stays a question about source-files.json")
        XCTAssertEqual(FASTQBundle.resolvePrimaryFASTQURL(for: bundle)?.lastPathComponent, "s_R1.fastq")
    }

    func testPreviewFileIsNotAMateOfAPairedRoot() throws {
        let bundle = try makeRoot(files: [
            ("s_R1.fastq", reads("r1_", sequence: "ACGT", quality: "I")),
            ("s_R2.fastq", reads("r2_", sequence: "GGCC", quality: "+")),
            ("preview.fastq", reads("p_", sequence: "ACGT", quality: "I")),
        ])

        let resolved = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: bundle))

        XCTAssertEqual(resolved.map(\.lastPathComponent), ["s_R1.fastq", "s_R2.fastq"])
    }

    /// Pins the answers that do not change. Each passes at the base.
    func testASingleFileRootAndADerivedBundleResolveAsBefore() throws {
        let single = try makeRoot(named: "single", files: [("reads.fastq", reads("r_", sequence: "ACGT", quality: "I"))])
        XCTAssertEqual(FASTQBundle.resolveAllFASTQURLs(for: single)?.map(\.lastPathComponent), ["reads.fastq"])

        let withPreview = try makeRoot(named: "with-preview", files: [
            ("reads.fastq", reads("r_", sequence: "ACGT", quality: "I")),
            ("preview.fastq", reads("p_", sequence: "ACGT", quality: "I")),
        ])
        XCTAssertEqual(FASTQBundle.resolveAllFASTQURLs(for: withPreview)?.map(\.lastPathComponent), ["reads.fastq"])

        // A derived bundle names its payload and roles in its manifest, so it keeps its one answer.
        let derived = try makeRoot(named: "derived", files: [
            ("a_R1.fastq", reads("a_", sequence: "ACGT", quality: "I")),
            ("b_R2.fastq", reads("b_", sequence: "GGCC", quality: "+")),
            (FASTQBundle.derivedManifestFilename, "{}"),
        ])
        XCTAssertEqual(FASTQBundle.resolveAllFASTQURLs(for: derived)?.map(\.lastPathComponent), ["a_R1.fastq"])

        let file = single.appendingPathComponent("reads.fastq")
        XCTAssertEqual(FASTQBundle.resolveAllFASTQURLs(for: file), [file], "a FASTQ file is its own answer")
    }

    func testExportOfPairedRootWritesBothMates() async throws {
        let bundle = try makePairedRoot()

        let source = try FASTQReadsExport.source(of: bundle)
        XCTAssertEqual(source.chunkURLs.map(\.lastPathComponent), ["s_R1.fastq", "s_R2.fastq"])
        XCTAssertEqual(
            source.inputURLs.map(\.lastPathComponent), ["s_R1.fastq", "s_R2.fastq"],
            "the record names both mates as inputs"
        )

        let staged = root.appendingPathComponent("exported.fastq")
        try await FASTQReadsExport.write(source, to: staged, outputIsGzip: false)

        let lines = try String(contentsOf: staged, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count / 4, 8, "the export holds the reads of both mates")
        XCTAssertEqual(lines.first, "@r1_1", "R1 comes first")
        XCTAssertTrue(lines.contains("@r2_4"), "the last read of R2 is in the export")
    }
}
