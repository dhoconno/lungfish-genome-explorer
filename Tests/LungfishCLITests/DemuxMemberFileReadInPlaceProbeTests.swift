// DemuxMemberFileReadInPlaceProbeTests.swift - What the CLI reads when it is handed one member file of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session probe PROBES-B, row DEMUX-MEMBER-FILE-READ-IN-PLACE. `FASTQSubcommandInput.resolve` is the resolver that the
// `fastq` subcommands run on a typed path. A path to a file inside a `.lungfishfastq` bundle is read in place, as one file,
// where the bundle's path is materialized as all of its reads. The Tools menu dialog promotes a file in a bundle to its
// bundle before it builds the request (`AppDelegate+ToolsMenu.resolveFASTQOperationInputURL`), so this pins the other
// half, the person who types the member path. No tool runs and nothing is materialized.

import Foundation
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

    /// A bundle of two chunk files, three reads in the first and two in the second.
    private func twoChunkBundle() throws -> (bundle: URL, chunk1: URL, chunk2: URL) {
        let bundle = root.appendingPathComponent("two-chunk.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        func fastq(_ reads: Int, _ tag: String) -> String {
            (1...reads).map { "@\(tag)_\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        }
        let chunk1 = bundle.appendingPathComponent("chunk-1.fastq")
        let chunk2 = bundle.appendingPathComponent("chunk-2.fastq")
        try fastq(3, "c1").write(to: chunk1, atomically: true, encoding: .utf8)
        try fastq(2, "c2").write(to: chunk2, atomically: true, encoding: .utf8)
        return (bundle, chunk1, chunk2)
    }

    func testAMemberFileOfATwoChunkBundleIsReadInPlaceAsOneChunk() async throws {
        let fixture = try twoChunkBundle()
        let input = try await FASTQSubcommandInput.resolve(
            fixture.chunk1.path, operationName: "demultiplex", contextURL: root.appendingPathComponent("out")
        )
        XCTAssertEqual(input.executionURL.standardizedFileURL.path, fixture.chunk1.standardizedFileURL.path, "read in place")
        XCTAssertFalse(input.wasMaterialized, "nothing was materialized, so the other chunk is never read")
        XCTAssertEqual(input.bundleURL?.standardizedFileURL.path, fixture.bundle.standardizedFileURL.path)
        let read = try String(contentsOf: input.executionURL, encoding: .utf8)
        XCTAssertEqual(read.split(separator: "\n").filter { $0.hasPrefix("@") }.count, 3, "chunk 1's three reads, not the bundle's five")
        XCTAssertFalse(read.contains("c2_"), "no read of chunk 2")
    }
}
