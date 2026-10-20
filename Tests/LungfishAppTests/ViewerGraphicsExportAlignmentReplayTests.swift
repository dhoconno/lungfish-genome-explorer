// ViewerGraphicsExportAlignmentReplayTests.swift - The viewer image export of a bundle with a read track
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2), M3, BIO ruling Q-G3 item 8, QA ruling QA-GFX-mask items 4 and 5, X14. The alignment
// case of `ViewerGraphicsExportCLIGUIParityReplayTests` in all four formats, and a SIGTERM while the leaf hashes a BAM
// of more than 2 GiB for its record. samtools draws the read track, so each test skips without it unless
// `LUNGFISH_REQUIRE_TOOLS=1`. It launches the built lungfish-cli, so its name ends in ReplayTests (the integration
// tier).

import AppKit
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViewerGraphicsExportAlignmentReplayTests: XCTestCase {
    typealias Parity = ViewerGraphicsExportCLIGUIParityReplayTests

    var scratch: URL!
    var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "viewer-graphics-alignment")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// The alignment case in PNG, JPEG, TIFF and PDF. Side C' replays side C's command to the same bytes and record
    /// digest, side A is measured against side C, and each record names the BAM and its index as inputs (BIO ruling
    /// Q-G3 item 5).
    func testAlignmentCaseMatchesItsReplayInEachFormat() async throws {
        try await requireSamtools()
        for format in ViewerGraphicFormat.allCases {
            let runs = try await Parity.assertCase(.alignment, format, scratch: scratch, harness: harness, testCase: self)
            let figure = runs.c.root.appendingPathComponent("figure.\(format.fileExtension)")
            let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: figure)))
            let inputs = record.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            XCTAssertTrue(inputs.contains("reads.bam") && inputs.contains("reads.bam.bai"), "\(format): \(inputs)")
        }
    }

    /// M3 item 1, X14. SIGTERM through the app's transport while the leaf hashes the BAM for its record exits 125
    /// inside the grace with no process left, and leaves no figure, no record and no staged file. The BAM is the
    /// samtools one with a hole of 2 GiB before its end-of-file block, so its index still reads and it takes no disk
    /// space. The test prints the wall time to hash it next to the wall time of a whole run with the small BAM.
    func testExportGraphicCancelDuringInputHashingLeavesNothing() async throws {
        try await requireSamtools()
        let root = scratch.appendingPathComponent("hash/case/run/root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Parity.makeBundle(.alignment, in: root)
        let bundle = Parity.bundleURL(in: root)
        let output = root.appendingPathComponent("figure.png")
        let arguments = [
            "bundle", "export-graphic", bundle.path, "--region", "chr1:1101-1300", "--output-format", "png", "-o", output.path,
        ]

        let runStart = ContinuousClock.now
        let small = await RouteParityHarness.runCLI(harness.cliBinary, arguments: arguments, timeout: .seconds(120))
        let runTime = ContinuousClock.now - runStart
        XCTAssertEqual(small.end, .completed, small.detail)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: output))

        let bam = bundle.appendingPathComponent("alignments/reads.bam")
        let size = try Self.addHole(of: 2 << 30, beforeTheEndOf: bam)
        let hashStart = ContinuousClock.now
        _ = try ProvenanceFileHasher.sha256(of: bam)
        let hashTime = ContinuousClock.now - hashStart
        print("Viewer export hashing: \(size) bytes of BAM hashed in \(hashTime), a whole run with the small BAM took \(runTime)")

        let bamPath = bam.path
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(120),
            cancelWhen: { Self.cliHoldsOpen(bamPath) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled while it hashed, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        try Parity.assertNothingLeft(in: root, output: output)
    }

    // MARK: - Helpers

    /// Moves the 28-byte end-of-file block of `bam` `size` bytes further on, leaving a hole that reads as zeros and
    /// takes no disk space. Every offset the index names stays where it was. Returns the new size.
    static func addHole(of size: UInt64, beforeTheEndOf bam: URL) throws -> UInt64 {
        let data = try Data(contentsOf: bam)
        let endOfFile = data.suffix(28)
        XCTAssertEqual(endOfFile.prefix(4), Data([0x1F, 0x8B, 0x08, 0x04]), "the BAM ends in a BGZF block")
        let handle = try FileHandle(forWritingTo: bam)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(data.count - 28))
        try handle.seek(toOffset: UInt64(data.count - 28) + size)
        try handle.write(contentsOf: endOfFile)
        return try handle.offset()
    }

    /// Whether a `lungfish-cli` this test started holds `path` open. The samtools it runs to read the reads opens the
    /// BAM too, so that one does not count.
    nonisolated static func cliHoldsOpen(_ path: String) -> Bool {
        ProcessTreeTerminator.descendantProcessIDs(of: getpid()).contains { pid in
            var name = [CChar](repeating: 0, count: 64)
            proc_name(pid, &name, UInt32(name.count))
            let executable = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return executable == CLICommandIdentity.executableName && OpenFileProbe.process(pid, holdsOpen: path)
        }
    }

    private func requireSamtools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            try ToolAvailability.skipOrFail("Managed samtools is required to draw a read track: \(error)", file: file, line: line)
        }
    }
}
