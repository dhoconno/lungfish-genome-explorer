// ONTDemultiplexVirtualInputTests.swift - The ONT sample splits read a virtual input's reads, never its preview
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `fastq ont-fluidigm-samples`, the Fluidigm amplicon split and
// `fastq ont-pacbio-barcode-demux` resolve their input bundle through the
// genotyping input resolution. A virtual bundle used to resolve to its
// preview, so the split read the preview's records and left the rest of
// the sample out. A virtual bundle is now materialized first, by the managed
// seqkit, so these tests skip without it.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ONTDemultiplexVirtualInputTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-demux-virtual-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let cs1 = "ACACTGACGACATGGTTCTACA"
    private static let cs2rc = "AGACCAAGTCTCTGCTACCGTA"
    private static let barcodeA = "AAAACCCCGG"
    private static let barcodeB = "GGGGTTTTAA"

    private func writeFluidigmBarcodes() throws -> URL {
        let url = root.appendingPathComponent("samples.csv")
        try "sample,barcode\nLF2871,\(Self.barcodeA)\nLF2872,\(Self.barcodeB)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Four reads: two of sample A, one of sample B and one that matches no
    /// barcode. The subset lists every read and its preview holds read-1.
    private func makeFluidigmSubset(insertA: String, insertB: String, rightPrimer: String) throws -> URL {
        let readA = Self.cs1 + insertA + rightPrimer + "CC" + Self.barcodeA
        let readB = Self.cs1 + insertB + rightPrimer + "AA" + Self.barcodeB
        return try GenotypingVirtualInputFixtures.makeONTSubset(
            in: root,
            reads: [("read-1", readA), ("read-2", readA), ("read-3", readB), ("read-4", "NNNNNNNNNNNNNNNN")],
            listed: ["read-1", "read-2", "read-3", "read-4"],
            preview: ["read-1"]
        )
    }

    /// Before: 1 input read, the preview's read-1.
    func testTheFluidigmSampleSplitReadsEveryReadOfAVirtualInput() async throws {
        try await GenotypingVirtualInputFixtures.requireSeqkit()
        let input = try makeFluidigmSubset(insertA: "ACGTACGTACGTACGT", insertB: "TTTTCCCCAAAAGGGG", rightPrimer: Self.cs2rc)

        let result = try await ONTFluidigmSampleMaterializer().run(
            ONTFluidigmSampleMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: try writeFluidigmBarcodes(),
                outputDirectory: root.appendingPathComponent("fluidigm-samples", isDirectory: true),
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 4)
        XCTAssertEqual(result.assignedReadCount, 3)
        XCTAssertEqual(result.unassignedReadCount, 1)
    }

    /// Before: 1 input read, the preview's read-1.
    func testTheFluidigmAmpliconSplitReadsEveryReadOfAVirtualInput() async throws {
        try await GenotypingVirtualInputFixtures.requireSeqkit()
        let rightPrimer = Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        let input = try makeFluidigmSubset(insertA: "ACGTACGTACGTACGT", insertB: "TTTTCCCCAAAAGGGG", rightPrimer: rightPrimer)

        let result = try await ONTFluidigmAmpliconMaterializer().run(
            ONTFluidigmAmpliconMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: try writeFluidigmBarcodes(),
                outputDirectory: root.appendingPathComponent("fluidigm-amplicons", isDirectory: true),
                primerMismatches: 0,
                minimumInsertLength: 8,
                canonicalizeReverseComplements: false,
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 4)
        XCTAssertEqual(result.assignedReadCount, 3)
        XCTAssertEqual(result.extractedReadCount, 3)
    }

    /// Before: 1 assigned read and none unassigned, the preview's read-1.
    func testThePacBioBarcodeSplitReadsEveryReadOfAVirtualInput() async throws {
        try await GenotypingVirtualInputFixtures.requireSeqkit()
        let forward = "CACATATCAGAGTGCG"
        let reverse = "CTATACATAGTGATGT"
        let insert = String(repeating: "ACGT", count: 510)
        let sampleRead = String(repeating: "T", count: 60) + forward + insert + Self.reverseComplement(reverse) + String(repeating: "A", count: 60)
        let offTarget = String(repeating: "N", count: sampleRead.count)
        let input = try GenotypingVirtualInputFixtures.makeONTSubset(
            in: root,
            reads: [("read-1", sampleRead), ("read-2", offTarget), ("read-3", sampleRead)],
            listed: ["read-1", "read-2", "read-3"],
            preview: ["read-1"]
        )
        let barcodes = root.appendingPathComponent("plate.barcodes.csv")
        try "32286-001_DL46,BC1001,BC1021\n".write(to: barcodes, atomically: true, encoding: .utf8)

        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(
            ONTPacBioBarcodeDemuxMaterializationRequest(
                inputURL: input,
                barcodeDefinitionsURL: barcodes,
                outputDirectory: root.appendingPathComponent("pacbio-demux", isDirectory: true),
                force: true,
                threads: 1,
                chunkJobs: 1,
                maxReadsPerSlice: 0
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.assignedReadCount, 2)
        XCTAssertEqual(result.unassignedReadCount, 1)
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return "N"
            }
        })
    }
}
