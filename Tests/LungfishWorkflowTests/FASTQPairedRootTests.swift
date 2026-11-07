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

    /// A root of two chunk files that a `source-files.json` lists: chunks of one read set, not a pair.
    private func makeChunkedRoot() throws -> URL {
        let chunked = try makeRoot(named: "chunked", files: [
            ("chunk_1.fastq", reads("c1_", sequence: "ACGT", quality: "I")),
            ("chunk_2.fastq", reads("c2_", sequence: "ACGT", quality: "I")),
        ])
        let entries = ["chunk_1.fastq", "chunk_2.fastq"].map {
            FASTQSourceFileManifest.SourceFileEntry(filename: $0, originalPath: "/original/\($0)", sizeBytes: 1, isSymlink: false)
        }
        try FASTQSourceFileManifest(files: entries).save(to: chunked)
        return chunked
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

    /// A `source-files.json` that cannot be read still marks the root as a manifest root, so the root keeps the primary
    /// answer it had and does not list its top-level files as a pair (PAIREDROOT-SWIFT SF2).
    func testRootWithAnUnreadableSourceManifestKeepsItsPrimaryAnswer() throws {
        let bundle = try makeRoot(named: "damaged-manifest", files: [
            ("a_R1.fastq", reads("a_", sequence: "ACGT", quality: "I")),
            ("b_R2.fastq", reads("b_", sequence: "GGCC", quality: "+")),
            ("source-files.json", "{"),
        ])

        XCTAssertTrue(FASTQBundle.isMultiFileBundle(bundle))
        XCTAssertEqual(FASTQBundle.resolveAllFASTQURLs(for: bundle)?.map(\.lastPathComponent), ["a_R1.fastq"])
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

        // What "both mates" means here: the R1 file's reads and then the R2 file's, each in its own order. The export is
        // not an interleaved file, so a tool that reads it as adjacent pairs would pair the wrong reads (PAIREDROOT-BIO S-2).
        let headers = stride(from: 0, to: lines.count, by: 4).map { lines[$0] }
        XCTAssertEqual(
            headers, ["@r1_1", "@r1_2", "@r1_3", "@r1_4", "@r2_1", "@r2_2", "@r2_3", "@r2_4"],
            "R1 file then R2 file, each in its own order"
        )
        XCTAssertEqual(lines[3], "IIII", "R1 keeps its Q40 line")
        XCTAssertEqual(lines[19], "++++", "R2 keeps its Q10 line")
    }

    // MARK: - The exact-barcode engines refuse a root of R1 and R2 files (PAIREDROOT-BIO B1)

    /// The exact bare-barcode engine over the whole of `bundle`, as the app and `fastq demultiplex --engine exact-bare` build it.
    private func exactBareConfig(reading bundle: URL, output: URL) throws -> DemultiplexConfig {
        let kitCSV = root.appendingPathComponent("kit-\(UUID().uuidString).csv")
        try "id,sequence\nBC01,ACGTACGTACGT\n".write(to: kitCSV, atomically: true, encoding: .utf8)
        return DemultiplexConfig(
            inputURL: bundle,
            sourceBundleURL: bundle,
            barcodeKit: try BarcodeKitRegistry.loadCustomKit(from: kitCSV, name: "kit"),
            outputDirectory: output,
            engine: .exactBareBarcode,
            inputSequenceFormat: .fastq
        )
    }

    /// The exact engine for an asymmetric kit with sample assignments, the second engine that lists a bundle's files.
    private func asymmetricConfig(reading bundle: URL, output: URL) -> DemultiplexConfig {
        let forward = "ACGTTCAGGATCCTAGCATGCGAT"
        let reverse = "TTGACCGGTAACGTCAGTCAGGCA"
        let kit = BarcodeKitDefinition(
            id: "paired-root-asymmetric",
            displayName: "Paired root asymmetric",
            vendor: "pacbio",
            platform: .pacbio,
            kitType: .custom,
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: [BarcodeEntry(id: "bcA", i7Sequence: forward, i5Sequence: reverse)]
        )
        let assignment = FASTQSampleBarcodeAssignment(
            sampleID: "SampleA", sampleName: "Sample A", forwardBarcodeID: "bcA", forwardSequence: forward,
            reverseBarcodeID: nil, reverseSequence: reverse, metadata: [:]
        )
        return DemultiplexConfig(
            inputURL: bundle,
            sourceBundleURL: bundle,
            barcodeKit: kit,
            outputDirectory: output,
            symmetryMode: .asymmetric,
            sampleAssignments: [assignment],
            inputSequenceFormat: .fastq,
            minimumInsert: 20
        )
    }

    /// A run of `config` stops on the refusal and leaves nothing in `output`.
    private func assertRunRefuses(
        _ config: DemultiplexConfig, output: URL, engine: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })
            XCTFail("\(engine) ran on a root of R1 and R2 files", file: file, line: line)
        } catch DemultiplexError.fileSetNeedsInterleaving(_, let fileNames) {
            XCTAssertEqual(fileNames, ["s_R1.fastq", "s_R2.fastq"], engine, file: file, line: line)
        } catch {
            XCTFail("\(engine) threw \(error), not the refusal", file: file, line: line)
        }
        let visible = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(visible, [], "\(engine) wrote nothing before it refused", file: file, line: line)
    }

    /// Both exact-barcode engines call every read on its own, so the R1 and R2 of one sample would not follow one call:
    /// half the reads went to unassigned with no word. A root of R1 and R2 files with no `source-files.json` is refused
    /// with words, before any file is written.
    func testExactBarcodeEnginesRefuseARootOfR1AndR2WithWords() async throws {
        let bundle = try makePairedRoot()
        let bareOutput = root.appendingPathComponent("bare-out", isDirectory: true)
        let config = try exactBareConfig(reading: bundle, output: bareOutput)

        XCTAssertThrowsError(try DemultiplexingPipeline.requireNoUnmanifestedFileSet(config: config)) { error in
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(words.contains("s_R1.fastq"), "the words name R1: \(words)")
            XCTAssertTrue(words.contains("s_R2.fastq"), "the words name R2: \(words)")
            XCTAssertTrue(words.contains("nothing was run"), "the words say nothing was run: \(words)")
        }

        await assertRunRefuses(config, output: bareOutput, engine: "the exact bare-barcode engine")
        let asymmetricOutput = root.appendingPathComponent("asymmetric-out", isDirectory: true)
        await assertRunRefuses(
            asymmetricConfig(reading: bundle, output: asymmetricOutput),
            output: asymmetricOutput,
            engine: "the exact asymmetric engine"
        )
    }

    /// A root with a `source-files.json` is chunks of one read set, and keeps reading as chunks.
    func testExactBarcodeEnginesStillReadAManifestRootAsChunks() throws {
        let chunked = try makeChunkedRoot()
        XCTAssertTrue(FASTQBundle.isMultiFileBundle(chunked))

        let config = try exactBareConfig(reading: chunked, output: root.appendingPathComponent("chunked-out", isDirectory: true))
        XCTAssertNoThrow(try DemultiplexingPipeline.requireNoUnmanifestedFileSet(config: config))
        XCTAssertEqual(
            FASTQBundle.resolveAllFASTQURLs(for: chunked)?.map(\.lastPathComponent), ["chunk_1.fastq", "chunk_2.fastq"],
            "both chunks are still the inputs"
        )
    }

    /// A one-file root, a root with a preview and a derived bundle keep their exact path.
    func testExactBarcodeEnginesStillReadAOneFileRoot() throws {
        let single = try makeRoot(named: "single-file", files: [("reads.fastq", reads("r_", sequence: "ACGT", quality: "I"))])
        let withPreview = try makeRoot(named: "with-preview", files: [
            ("reads.fastq", reads("r_", sequence: "ACGT", quality: "I")),
            ("preview.fastq", reads("p_", sequence: "ACGT", quality: "I")),
        ])
        let derived = try makeRoot(named: "derived", files: [
            ("a_R1.fastq", reads("a_", sequence: "ACGT", quality: "I")),
            ("b_R2.fastq", reads("b_", sequence: "GGCC", quality: "+")),
            (FASTQBundle.derivedManifestFilename, "{}"),
        ])

        for bundle in [single, withPreview, derived] {
            let config = try exactBareConfig(reading: bundle, output: root.appendingPathComponent("out-\(bundle.lastPathComponent)", isDirectory: true))
            XCTAssertNoThrow(try DemultiplexingPipeline.requireNoUnmanifestedFileSet(config: config), bundle.lastPathComponent)
        }
    }
}
