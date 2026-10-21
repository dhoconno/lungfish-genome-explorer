// FastqCompressHonestTests.swift - What --compress does in the 23 fastq subcommands that take OutputOptions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.39 (COMPRESS-HONEST), milestone M1. `OutputOptions` gives the 23 `fastq` subcommands that
// take it a `--compress` flag whose help says "Compress output with gzip". Twenty of them never read the flag
// except to write `--compress` into the argv of their record and `compress` into its parameters, so they write
// plain bytes and the record says `compress` is true. `merge`, `materialize` and `scrub-human` do gzip.
//
// These cases pin the base before any Sources edit. All 23 parse the flag, `materialize` gzips (it needs no
// external tool) and the record of each gzip writer names `compress` only when the bytes are gzip. The cases
// of `merge` and `scrub-human` run the real tool, so they sit in the Conformance class and skip where the tool
// is missing. The run of `translate` stays in `TranslateFramePinTests`.

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

    /// Parses `arguments` with an output in the test folder and `--compress`, and checks the flag arrived.
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
    }

    // MARK: The 23 subcommands, each parsed with --compress

    func testAdapterTrimAcceptsCompress() throws {
        try assertAcceptsCompress(FastqAdapterTrimSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testContaminantFilterAcceptsCompress() throws {
        try assertAcceptsCompress(FastqContaminantFilterSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testDeduplicateAcceptsCompress() throws {
        try assertAcceptsCompress(FastqDeduplicateSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testEntropyFilterAcceptsCompress() throws {
        try assertAcceptsCompress(FastqEntropyFilterSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testErrorCorrectAcceptsCompress() throws {
        try assertAcceptsCompress(FastqErrorCorrectSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testFixedTrimAcceptsCompress() throws {
        try assertAcceptsCompress(FastqFixedTrimSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testInterleaveAcceptsCompress() throws {
        try assertAcceptsCompress(FastqInterleaveSubcommand.self, ["--in1", "r1.fastq", "--in2", "r2.fastq"], \.output.compress)
    }

    func testLengthFilterAcceptsCompress() throws {
        try assertAcceptsCompress(FastqLengthFilterSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testMaterializeAcceptsCompress() throws {
        try assertAcceptsCompress(FastqMaterializeSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testMergeAcceptsCompress() throws {
        try assertAcceptsCompress(FastqMergeSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testOrientAcceptsCompress() throws {
        try assertAcceptsCompress(FastqOrientSubcommand.self, ["in.fastq", "--reference", "ref.fasta"], \.output.compress)
    }

    func testPrimerRemovalAcceptsCompress() throws {
        try assertAcceptsCompress(FastqPrimerRemovalSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testQCSummaryAcceptsCompress() throws {
        try assertAcceptsCompress(FastqQCSummarySubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testQualityTrimAcceptsCompress() throws {
        try assertAcceptsCompress(FastqQualityTrimSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testRepairAcceptsCompress() throws {
        try assertAcceptsCompress(FastqRepairSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testReverseComplementAcceptsCompress() throws {
        try assertAcceptsCompress(FastqReverseComplementSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testScrubHumanAcceptsCompress() throws {
        try assertAcceptsCompress(FastqScrubHumanSubcommand.self, ["in.fastq", "--database-id", "deacon-panhuman"], \.output.compress)
    }

    func testSearchMotifAcceptsCompress() throws {
        try assertAcceptsCompress(FastqSearchMotifSubcommand.self, ["in.fastq", "--pattern", "ACGT"], \.output.compress)
    }

    func testSearchTextAcceptsCompress() throws {
        try assertAcceptsCompress(FastqSearchTextSubcommand.self, ["in.fastq", "--query", "frag"], \.output.compress)
    }

    func testSequenceFilterAcceptsCompress() throws {
        try assertAcceptsCompress(FastqSequenceFilterSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testSubsampleAcceptsCompress() throws {
        try assertAcceptsCompress(FastqSubsampleSubcommand.self, ["in.fastq"], \.output.compress)
    }

    func testTrimAcceptsCompress() throws {
        try assertAcceptsCompress(FastqTrimSubcommand.self, ["in.fastq"], \.output.compress)
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
