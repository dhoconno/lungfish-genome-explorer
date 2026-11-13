// DemuxMemberFileReadInPlaceProbeTests.swift - What the CLI reads when it is handed one file of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session row DEMUX-MEMBER-FILE-READ-IN-PLACE (probe PROBES-B, fix FIX-S1-SMALL). `FASTQSubcommandInput.resolve` is the
// resolver that the `fastq` subcommands run on a typed path. A file inside a multi-file bundle (an ONT import or a merge,
// listed in `source-files.json`) is a part of one sample, so the resolver reads the whole bundle, as the Tools menu dialog
// and `assemble` do, and a demultiplex of one chunk is never a count of part of the run with no word. A file inside a root
// that no `source-files.json` describes (the R1 and R2 of a pair) is a person's explicit choice and is still read where it
// is (`FastqSubcommandPairedRootTests`). No tool runs.

import Foundation
import LungfishIO
import XCTest
@testable import LungfishCLI

final class DemuxMemberFileReadInPlaceProbeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-member-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A bundle of two chunk files, three reads in the first and two in the second. With `manifest` it lists them in
    /// `source-files.json`, as an ONT import or a merge does, and without it the bundle is a root of two loose files.
    private func twoChunkBundle(manifest: Bool) throws -> (bundle: URL, chunk1: URL, chunk2: URL) {
        let bundle = root.appendingPathComponent("two-chunk.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        func fastq(_ reads: Int, _ tag: String) -> String {
            (1...reads).map { "@\(tag)_\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        }
        let chunk1 = bundle.appendingPathComponent("chunk-1.fastq")
        let chunk2 = bundle.appendingPathComponent("chunk-2.fastq")
        try fastq(3, "c1").write(to: chunk1, atomically: true, encoding: .utf8)
        try fastq(2, "c2").write(to: chunk2, atomically: true, encoding: .utf8)
        if manifest {
            let entries = [chunk1, chunk2].map {
                FASTQSourceFileManifest.SourceFileEntry(
                    filename: $0.lastPathComponent, originalPath: $0.path,
                    sizeBytes: Int64((try? Data(contentsOf: $0).count) ?? 0), isSymlink: false
                )
            }
            try FASTQSourceFileManifest(files: entries).save(to: bundle)
        }
        return (bundle, chunk1, chunk2)
    }

    private func readNames(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("@") }.map(String.init)
    }

    func testAFileOfAMultiFileBundleIsReadAsTheWholeBundle() async throws {
        let fixture = try twoChunkBundle(manifest: true)
        let input = try await FASTQSubcommandInput.resolve(
            fixture.chunk1.path, operationName: "demultiplex", contextURL: root.appendingPathComponent("out")
        )
        defer { input.cleanup() }
        XCTAssertTrue(input.wasMaterialized, "the bundle's files are joined, so chunk 1 is not read on its own")
        XCTAssertNotEqual(input.executionURL.standardizedFileURL.path, fixture.chunk1.standardizedFileURL.path)
        XCTAssertEqual(input.bundleURL?.standardizedFileURL.path, fixture.bundle.standardizedFileURL.path)
        XCTAssertEqual(
            try readNames(in: input.executionURL), ["@c1_1", "@c1_2", "@c1_3", "@c2_1", "@c2_2"],
            "chunk 1's three reads and chunk 2's two, in manifest order"
        )
    }

    func testAFileOfARootWithNoSourceFilesManifestIsStillReadWhereItIs() async throws {
        let fixture = try twoChunkBundle(manifest: false)
        let input = try await FASTQSubcommandInput.resolve(
            fixture.chunk1.path, operationName: "demultiplex", contextURL: root.appendingPathComponent("out")
        )
        defer { input.cleanup() }
        XCTAssertEqual(input.executionURL.standardizedFileURL.path, fixture.chunk1.standardizedFileURL.path, "read in place")
        XCTAssertFalse(input.wasMaterialized, "nothing was materialized, so the other file is never read")
        XCTAssertEqual(input.bundleURL?.standardizedFileURL.path, fixture.bundle.standardizedFileURL.path)
        XCTAssertEqual(try readNames(in: input.executionURL), ["@c1_1", "@c1_2", "@c1_3"], "the named file's reads, a person's choice")
    }
}
