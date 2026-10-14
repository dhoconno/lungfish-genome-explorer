// FastqImportONTOptimizeStorageConformanceTests.swift - The one managed tool `fastq import-ont` runs, with the real tool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M1 (live form, 2.9 O5). The ONT import runs a managed tool only for
// `--optimize-storage`, which hands each flattened barcode bundle to bbtools `clumpify.sh` through
// `FASTQIngestionPipeline` (ONTImportWorkflowTests pin the split at the workflow's seam). This class runs
// the leaf in process with the real tool and pins what the step leaves, so the parity class of M3 and the
// CLI route start from a measured result. A name with `Conformance` keeps it out of the unit tier. It skips
// where bbtools is missing and fails when LUNGFISH_REQUIRE_TOOLS=1 is set.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class FastqImportONTOptimizeStorageConformanceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ont-optimize-storage-live")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    func testOptimizeStorageClumpifiesEachFlattenedBarcodeBundleAndRecordsTheStep() async throws {
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        let source = try makeSource(barcodes: ["barcode01": 12, "barcode02": 9])
        let output = root.appendingPathComponent("optimized", isDirectory: true)

        try await FastqImportONTSubcommand.parse([
            source.path, "--output", output.path, "--concurrency", "1",
            "--storage-mode", "flattened", "--optimize-storage",
        ]).run()

        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        XCTAssertEqual(
            manifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)" }, ["barcode01=12", "barcode02=9"],
            "clumpify reorders reads and never drops one"
        )
        for barcode in ["barcode01", "barcode02"] {
            let bundle = output.appendingPathComponent("\(barcode).lungfishfastq", isDirectory: true)
            let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), barcode)
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path), barcode)
            let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: bundle)?.ingestion, "\(barcode) records its ingestion")
            XCTAssertTrue(ingestion.isClumpified, "\(barcode) records that clumpify ran")

            let data = try Data(contentsOf: bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
            XCTAssertTrue(
                envelope.steps.contains { $0.toolName.lowercased().contains("clumpify") },
                "\(barcode) records the clumpify step, it records \(envelope.steps.map(\.toolName))"
            )
        }
    }

    /// An ONT run folder with `reads` four-line records in each barcode, 60 bases long and different
    /// from each other.
    private func makeSource(barcodes: [String: Int]) throws -> URL {
        let source = root.appendingPathComponent("fastq_pass", isDirectory: true)
        let bases = Array("ACGT")
        for (barcode, reads) in barcodes {
            let directory = source.appendingPathComponent(barcode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var text = ""
            for index in 0..<reads {
                let sequence = String((0..<60).map { bases[($0 * 7 + index * 3 + $0 / 5) % 4] })
                text += "@\(barcode)-r\(index) runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=\(barcode)\n"
                text += "\(sequence)\n+\n\(String(repeating: "I", count: 60))\n"
            }
            try text.write(to: directory.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        }
        return source
    }
}
