// FASTQDerivedBundleManifestPlaceholderMarkTests+CountedReads.swift - Counted reads known by their own records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane FLUIDIGM-UNLINKED, ruling BIO-FLUIDIGM-UNLINKED (FLUIDIGM-OLD-UNLINKED-KEEP-Q40). Every route that left a
// Fluidigm dataset with no mark and no manifest chain to a marked bundle keeps the reads, and
// `CountedFASTQMaterializer` names each read `u%06d;size=N` and writes `I` on every base. The reader knows a dataset
// by those records, so a delete, a move, a copy or an export keeps the mark. Nothing is written.

import XCTest
@testable import LungfishIO

extension FASTQDerivedBundleManifestPlaceholderMarkTests {
    private static let pacBioLibraryPrep = "Full-length MHC ONT amplicon with PacBio barcode pairs"

    private static let storedCountedQ40 = FASTQDatasetStatistics(
        readCount: 3, baseCount: 30, meanReadLength: 10, minReadLength: 10, maxReadLength: 10,
        medianReadLength: 10, n50ReadLength: 10, meanQuality: 40, q20Percentage: 100, q30Percentage: 100,
        gcContent: 0.5, readLengthHistogram: [10: 3], qualityScoreHistogram: [40: 30], perPositionQuality: []
    )

    /// `records` reads in the form `CountedFASTQMaterializer.swift:151-153` writes, numbered from `first`.
    private static func unlinkedCountedText(records: Int = 3, from first: Int = 1) -> String {
        (first..<(first + records)).map { index in
            "@u\(String(format: "%06d", index));size=\(13 - index % 12)\nACGTACGTAC\n+\nIIIIIIIIII\n"
        }.joined()
    }

    /// A gzip stream of one stored block, so the test needs no tool.
    private static func unlinkedGzip(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc = ~crc
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        let length = UInt16(payload.count)
        out.append(contentsOf: [0x01, UInt8(length & 0xff), UInt8(length >> 8), UInt8(~length & 0xff), UInt8(~length >> 8)])
        out.append(contentsOf: payload)
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((crc >> UInt32(shift)) & 0xff)) }
        let size = UInt32(payload.count)
        for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((size >> UInt32(shift)) & 0xff)) }
        return out
    }

    private func unlinkedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("counted-reads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A bundle with no derived manifest that holds `text` as `filename` and the files in `extra`.
    private func unlinkedPlainBundle(
        in root: URL, text: String, filename: String = "reads.fastq", extra: [String: String] = [:]
    ) throws -> (bundle: URL, reads: URL) {
        let bundle = root.appendingPathComponent("\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent(filename)
        if filename.hasSuffix(".gz") {
            try Self.unlinkedGzip(text).write(to: reads)
        } else {
            try text.write(to: reads, atomically: true, encoding: .utf8)
        }
        for (name, contents) in extra {
            try contents.write(to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return (bundle, reads)
    }

    /// A derived bundle with no mark, whose manifest names `parent` as parent and root, with `text` as its own reads.
    private func unlinkedDerivedBundle(
        in root: URL, parent: String, libraryPrep: String? = nil, virtual: Bool = false, text: String
    ) throws -> (bundle: URL, reads: URL) {
        let bundle = root.appendingPathComponent("\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent(virtual ? "preview.fastq" : "reads.fastq")
        try text.write(to: reads, atomically: true, encoding: .utf8)
        let operation = virtual || libraryPrep != nil
            ? FASTQDerivativeOperation(kind: .demultiplex)
            : FASTQDerivativeOperation(kind: .subsampleCount, count: 2)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "unlinked", parentBundleRelativePath: parent, rootBundleRelativePath: parent,
                rootFASTQFilename: "reads.fastq.gz",
                payload: virtual
                    ? .demuxedVirtual(barcodeID: "bc1001", readIDListFilename: "read-ids.txt", previewFilename: "preview.fastq")
                    : .full(fastqFilename: "reads.fastq"),
                lineage: [operation], operation: operation, cachedStatistics: Self.storedCountedQ40, pairingMode: nil,
                provenance: libraryPrep.map { SampleProvenance(libraryPrep: $0) }
            ),
            in: bundle
        )
        return (bundle, reads)
    }

    /// One case per route of the ruling's table. No case holds a mark, a Fluidigm library prep or a marked ancestor.
    func testCountedReadsAreRecognizedWithNoManifestChain() throws {
        let root = try unlinkedRoot()
        let counted = Self.unlinkedCountedText()
        let merged = try unlinkedPlainBundle(in: root, text: counted, extra: ["merge-provenance.json": "{}"])
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: merged.bundle), "route (a): a plain bundle made by Merge into New Bundle, the bundle")
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: merged.reads), "route (a): the file inside it")

        let extracted = try unlinkedPlainBundle(in: root, text: counted, extra: ["extraction-metadata.json": "{}"])
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: extracted.bundle), "route (b): a plain bundle with extraction-metadata.json")

        let demuxed = try unlinkedDerivedBundle(in: root, parent: ".", libraryPrep: Self.pacBioLibraryPrep, text: counted)
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: demuxed.bundle), "route (c): the ONT barcode demultiplex, parent and root \".\", stored Q40, no mark")

        let deleted = try unlinkedDerivedBundle(in: root, parent: "../missing-source.lungfishfastq", text: counted)
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: deleted.bundle), "route (d): a subsample whose parent path names a missing bundle")
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: deleted.reads), "route (d): the file inside it")

        let moved = try unlinkedDerivedBundle(in: root, parent: "@/Imports/gone.lungfishfastq", text: counted)
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: moved.bundle), "route (e): a parent given as @/ that no longer resolves")

        let zipped = try unlinkedPlainBundle(in: root, text: counted, filename: "reads.fastq.gz")
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: zipped.bundle), "a gzip payload")

        let virtual = try unlinkedDerivedBundle(in: root, parent: "../missing-root.lungfishfastq", virtual: true, text: counted)
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: virtual.bundle), "a .demuxedVirtual child with only preview.fastq and a missing root")

        let longRun = try unlinkedPlainBundle(
            in: root, text: Self.unlinkedCountedText(records: 64) + "@read1\nACGTACGTAC\n+\n5555555555\n"
        )
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: longRun.bundle), "only the first 64 records are read")
    }

    /// Controls that pass at the base and at the fix: no other shape of reads is marked, and the reader looks at the
    /// first 64 records only.
    func testReadsThatAreNotCountedReadsAreNotMarkedByTheirOwnRecords() throws {
        let root = try unlinkedRoot()
        func marked(_ text: String) throws -> Bool {
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: try unlinkedPlainBundle(in: root, text: text).bundle)
        }
        let ordinaryI = (1...3).map { "@read\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        XCTAssertFalse(try marked(ordinaryI), "ordinary names with every score I, as FASTA converted with a fixed score")
        let oneBaseLower = "@u000001;size=3\nACGTACGTAC\n+\nIIIIIIIIII\n@u000002;size=3\nACGTACGTAC\n+\nIIIIIIIII5\n"
        XCTAssertFalse(try marked(oneBaseLower), "u000001;size=3 names with one base not I")
        let binned = (1...100).map { "@read\($0)\n\(String(repeating: "A", count: 100))\n+\n\(String(repeating: "I", count: 100))\n" }.joined()
        XCTAssertFalse(try marked(binned), "ordinary names, one score value 40 over 10,000 bases")
        XCTAssertFalse(try marked(""), "an empty file")
        XCTAssertFalse(try marked(Self.unlinkedCountedText().replacingOccurrences(of: "@u000003", with: "@read3")), "one record among three has an ordinary name")
        let scoredFirst = "@read1\nACGTACGTAC\n+\n5555555555\n" + Self.unlinkedCountedText()
        XCTAssertFalse(try marked(scoredFirst), "a merge that put scored reads ahead of counted reads is a Known limit")
        XCTAssertFalse(try marked(Self.unlinkedCountedText().replacingOccurrences(of: "@u000001", with: "@u0001")), "a name that is not zero-padded to six digits")

        // Not marked: the 64th record is an ordinary read. The other side of the bound (64 counted reads, then ordinary
        // ones, are marked) is red at the base and belongs to testCountedReadsAreRecognizedWithNoManifestChain.
        XCTAssertFalse(try marked(Self.unlinkedCountedText(records: 63) + ordinaryI), "the 64th record is an ordinary read")

        let empty = root.appendingPathComponent("\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: empty), "a bundle with no payload")
        let loose = root.appendingPathComponent("loose.fastq")
        try Self.unlinkedCountedText().write(to: loose, atomically: true, encoding: .utf8)
        XCTAssertFalse(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: loose), "a file in no bundle stays false")
    }
}
