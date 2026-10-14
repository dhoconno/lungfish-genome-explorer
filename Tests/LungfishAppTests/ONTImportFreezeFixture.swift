// ONTImportFreezeFixture.swift - The ONT run folder the import route tests share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M1. Three barcode folders with different read counts, so a route that swaps
// two barcodes or drops a chunk changes a number a test reads. barcode01 holds two chunks (2 and 1
// reads), barcode02 one gzip chunk (2 reads, the shape a sequencer writes, counted with `gzcat`)
// and unclassified one chunk (1 read). BIO 1 reads the per-barcode counts, and the parity class of
// M3 reuses the same folder.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishApp

enum ONTImportFreezeFixture {
    /// Reads in each barcode folder, in the order the importer lists them.
    static let readsPerBarcode: [(barcode: String, reads: Int)] = [
        ("barcode01", 3), ("barcode02", 2), ("unclassified", 1),
    ]

    /// Total reads of the three folders.
    static let totalReads = 6

    /// The built `lungfish-cli` beside the test bundle of `testCase`, or the one `LUNGFISH_CLI_PATH` names.
    /// The import route launches it, and a unit-tier test process has no installed one.
    static func builtCLI(for testCase: AnyClass) throws -> URL {
        let products = Bundle(for: testCase).bundleURL.deletingLastPathComponent()
        return try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so the import route cannot run"
        )
    }

    /// The L6 runner on the built command.
    @MainActor
    static func cliRunner(for testCase: AnyClass) throws -> CLIReadsRunner {
        CLIReadsRunner(cliURLOverride: try builtCLI(for: testCase))
    }

    /// Writes `<parent>/fastq_pass` and returns it.
    static func makeSource(in parent: URL) throws -> URL {
        let source = parent.appendingPathComponent("fastq_pass", isDirectory: true)
        try write(
            reads: ["r1", "r2"], barcode: "barcode01", chunk: "chunk_0.fastq", in: source
        )
        try write(reads: ["r3"], barcode: "barcode01", chunk: "chunk_1.fastq", in: source)
        try write(reads: ["r4", "r5"], barcode: "barcode02", chunk: "chunk_0.fastq", in: source, gzip: true)
        try write(reads: ["r6"], barcode: "unclassified", chunk: "chunk_0.fastq", in: source)
        return source
    }

    private static func write(
        reads: [String],
        barcode: String,
        chunk: String,
        in source: URL,
        gzip: Bool = false
    ) throws {
        let directory = source.appendingPathComponent(barcode, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = reads.map {
            "@\($0) runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=\(barcode) basecall_model_version_id=dorado-test\nACGTACGT\n+\nIIIIIIII\n"
        }.joined()
        let file = directory.appendingPathComponent(chunk)
        try text.write(to: file, atomically: true, encoding: .utf8)
        if gzip {
            let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-f", file.path])
            precondition(result.status == 0, "gzip failed: \(result.stderr)")
        }
    }
}
