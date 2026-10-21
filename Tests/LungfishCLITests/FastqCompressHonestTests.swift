// FastqCompressHonestTests.swift - What --compress does in the 23 fastq subcommands that take OutputOptions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.39 (COMPRESS-HONEST). `OutputOptions` used to give the 23 `fastq` subcommands that take it a
// `--compress` flag whose help said "Compress output with gzip". Twenty of them never read the flag except to
// write `--compress` into the argv of their record and `compress` into its options, so they wrote plain bytes
// and the record said `compress` was true. `merge`, `materialize` and `scrub-human` do gzip.
//
// Milestone M1 pinned that base with a parse case for each of the 23, and the gzip of the three that gzip. Both
// are in this file. The 20 plain writers now refuse `--compress` when their arguments are parsed (exit 64, the
// words of the tally), before any file or record exists, so each of their cases checks the message, the missing
// output and the missing sidecar. The three gzip writers keep their parse case, and `materialize` keeps its
// gzip case, which needs no external tool. The cases of `merge` and `scrub-human` run the real tool, so they sit
// in the Conformance class and skip where the tool is missing. The run of `translate` stays in
// `TranslateFramePinTests`.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// The first two bytes of `url`.
private func firstTwoBytes(_ url: URL) throws -> [UInt8] {
    Array(try Data(contentsOf: url).prefix(2))
}

/// The `compress` value the record beside `output` resolved, or nil when the record does not name it.
private func recordedCompress(of output: URL) throws -> ParameterValue? {
    let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
    let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecar), "no record beside \(output.lastPathComponent)")
    return envelope.options.resolvedDefaults["compress"]
}

private func makeCompressHonestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("fastq-compress-honest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

final class FastqCompressHonestTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeCompressHonestFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A plain writer. Its arguments parse without the flag, and with `--compress` they throw the refusal with the
    /// words of the tally. Parsing is all a refusal does, so no output file and no sidecar exist afterwards.
    private func assertRefusesCompress<C: ParsableCommand>(
        _ type: C.Type,
        _ name: String,
        _ arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let output = folder.appendingPathComponent("out.fastq")
        XCTAssertNoThrow(try C.parse(arguments + ["--output", output.path]), "\(name) parses without the flag", file: file, line: line)
        XCTAssertThrowsError(
            try C.parse(arguments + ["--output", output.path, "--compress"]),
            "\(name) refuses --compress",
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                C.message(for: error),
                "--compress is not supported by fastq \(name). Remove it to write plain output.",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(name) wrote no output", file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path),
            "\(name) wrote no sidecar",
            file: file,
            line: line
        )
        XCTAssertFalse(
            C.helpMessage(includeHidden: true).contains("--compress"),
            "\(name) lists --compress in its extended help",
            file: file,
            line: line
        )
    }

    /// A gzip writer. The flag parses and arrives in `output.compress`.
    private func assertAcceptsCompress<C: ParsableCommand>(
        _ type: C.Type,
        _ arguments: [String],
        _ compress: KeyPath<C, Bool>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let output = folder.appendingPathComponent("out.fastq").path
        let command = try C.parse(arguments + ["--output", output, "--compress"])
        XCTAssertTrue(command[keyPath: compress], "\(C.self) parses --compress", file: file, line: line)
        XCTAssertTrue(C.helpMessage().contains("--compress"), "\(C.self) lists --compress in its help", file: file, line: line)
    }

    // MARK: The 20 plain writers refuse --compress

    func testAdapterTrimRefusesCompress() {
        assertRefusesCompress(FastqAdapterTrimSubcommand.self, "adapter-trim", ["in.fastq"])
    }

    func testContaminantFilterRefusesCompress() {
        assertRefusesCompress(FastqContaminantFilterSubcommand.self, "contaminant-filter", ["in.fastq"])
    }

    func testDeduplicateRefusesCompress() {
        assertRefusesCompress(FastqDeduplicateSubcommand.self, "deduplicate", ["in.fastq"])
    }

    func testEntropyFilterRefusesCompress() {
        assertRefusesCompress(FastqEntropyFilterSubcommand.self, "entropy-filter", ["in.fastq"])
    }

    func testErrorCorrectRefusesCompress() {
        assertRefusesCompress(FastqErrorCorrectSubcommand.self, "error-correct", ["in.fastq"])
    }

    func testFixedTrimRefusesCompress() {
        assertRefusesCompress(FastqFixedTrimSubcommand.self, "fixed-trim", ["in.fastq"])
    }

    func testInterleaveRefusesCompress() {
        assertRefusesCompress(FastqInterleaveSubcommand.self, "interleave", ["--in1", "r1.fastq", "--in2", "r2.fastq"])
    }

    func testLengthFilterRefusesCompress() {
        assertRefusesCompress(FastqLengthFilterSubcommand.self, "length-filter", ["in.fastq"])
    }

    func testOrientRefusesCompress() {
        assertRefusesCompress(FastqOrientSubcommand.self, "orient", ["in.fastq", "--reference", "ref.fasta"])
    }

    func testPrimerRemovalRefusesCompress() {
        assertRefusesCompress(FastqPrimerRemovalSubcommand.self, "primer-remove", ["in.fastq"])
    }

    func testQCSummaryRefusesCompress() {
        assertRefusesCompress(FastqQCSummarySubcommand.self, "qc-summary", ["in.fastq"])
    }

    func testQualityTrimRefusesCompress() {
        assertRefusesCompress(FastqQualityTrimSubcommand.self, "quality-trim", ["in.fastq"])
    }

    func testRepairRefusesCompress() {
        assertRefusesCompress(FastqRepairSubcommand.self, "repair", ["in.fastq"])
    }

    func testReverseComplementRefusesCompress() {
        assertRefusesCompress(FastqReverseComplementSubcommand.self, "reverse-complement", ["in.fastq"])
    }

    func testSearchMotifRefusesCompress() {
        assertRefusesCompress(FastqSearchMotifSubcommand.self, "search-motif", ["in.fastq", "--pattern", "ACGT"])
    }

    func testSearchTextRefusesCompress() {
        assertRefusesCompress(FastqSearchTextSubcommand.self, "search-text", ["in.fastq", "--query", "frag"])
    }

    func testSequenceFilterRefusesCompress() {
        assertRefusesCompress(FastqSequenceFilterSubcommand.self, "sequence-filter", ["in.fastq"])
    }

    func testSubsampleRefusesCompress() {
        assertRefusesCompress(FastqSubsampleSubcommand.self, "subsample", ["in.fastq"])
    }

    func testTranslateRefusesCompress() {
        assertRefusesCompress(FastqTranslateSubcommand.self, "translate", ["in.fastq"])
    }

    func testTrimRefusesCompress() {
        assertRefusesCompress(FastqTrimSubcommand.self, "trim", ["in.fastq"])
    }

    // MARK: The 3 gzip writers accept it

    func testMaterializeAcceptsCompress() throws {
        try assertAcceptsCompress(FastqMaterializeSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testMergeAcceptsCompress() throws {
        try assertAcceptsCompress(FastqMergeSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testScrubHumanAcceptsCompress() throws {
        try assertAcceptsCompress(FastqScrubHumanSubcommand.self, ["in.fastq", "--database-id", "deacon-panhuman"], \.output.compress)
    }

    // MARK: materialize gzips and its record says so

    /// `--compress` makes the output gzip and the record names `compress` true. Without the flag the bytes are
    /// plain and the record names `compress` false. No external tool runs.
    func testMaterializeCompressGzipsAndTheRecordSaysSo() async throws {
        let reads = try InterleavedFASTQFixture.writeBundle(named: "pairs", in: folder, pairCount: 3, naming: .slashSuffix)
        let gzip = folder.appendingPathComponent("materialized.fastq.gz")
        let plain = folder.appendingPathComponent("materialized.fastq")

        try await FastqMaterializeSubcommand.parse([reads.bundleURL.path, "--output", gzip.path, "--compress"]).run()
        try await FastqMaterializeSubcommand.parse([reads.bundleURL.path, "--output", plain.path]).run()

        XCTAssertEqual(try firstTwoBytes(gzip), [0x1f, 0x8b])
        XCTAssertNotEqual(try firstTwoBytes(plain), [0x1f, 0x8b])
        XCTAssertEqual(try recordedCompress(of: gzip), .boolean(true))
        XCTAssertEqual(try recordedCompress(of: plain), .boolean(false))
    }
}

/// The two gzip writers that run a real tool. Both skip where the tool is missing, and fail under
/// `LUNGFISH_REQUIRE_TOOLS=1`.
final class FastqCompressHonestConformanceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeCompressHonestFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func requireNativeTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("\(tool.executableName) is not available in this test environment", file: file, line: line)
        }
    }

    /// `merge --compress` gzips the merged and unmerged reads and the record names `compress` true, and without
    /// the flag the bytes are plain and the record names `compress` false.
    func testMergeCompressGzipsAndTheRecordSaysSo() async throws {
        try await requireNativeTool(.bbmerge)
        let reads = try InterleavedFASTQFixture.writeBundle(named: "pairs", in: folder, pairCount: 4, naming: .slashSuffix)
        let gzip = folder.appendingPathComponent("merged.fastq.gz")
        let plain = folder.appendingPathComponent("merged.fastq")

        try await FastqMergeSubcommand.parse([reads.fastqURL.path, "--output", gzip.path, "--compress"]).run()
        try await FastqMergeSubcommand.parse([reads.fastqURL.path, "--output", plain.path]).run()

        XCTAssertEqual(try firstTwoBytes(gzip), [0x1f, 0x8b])
        XCTAssertNotEqual(try firstTwoBytes(plain), [0x1f, 0x8b])
        XCTAssertEqual(try recordedCompress(of: gzip), .boolean(true))
        XCTAssertEqual(try recordedCompress(of: plain), .boolean(false))
    }

    /// `scrub-human --compress` gzips through pigz and the record names `compress` true. The output name has no
    /// `.gz` suffix, so the flag is the only cause (`scrub-human` also gzips a `.gz` name and records that as
    /// `resolvedCompressOutput`).
    func testScrubHumanCompressGzipsAndTheRecordSaysSo() async throws {
        try await requireNativeTool(.deacon)
        try await requireNativeTool(.pigz)
        let databaseID = FastqScrubHumanSubcommand.canonicalHumanReadRemovalDatabaseID(for: "deacon-panhuman")
        guard (try? await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID)) != nil else {
            try ToolAvailability.skipOrFail("the \(databaseID) database is not installed in this test environment")
        }
        let reads = try InterleavedFASTQFixture.writeBundle(named: "pairs", in: folder, pairCount: 3, naming: .slashSuffix)
        let output = folder.appendingPathComponent("scrubbed.fastq")

        try await FastqScrubHumanSubcommand.parse(
            [reads.fastqURL.path, "--output", output.path, "--database-id", "deacon-panhuman", "--compress"]
        ).run()

        XCTAssertEqual(try firstTwoBytes(output), [0x1f, 0x8b])
        XCTAssertEqual(try recordedCompress(of: output), .boolean(true))
    }
}
