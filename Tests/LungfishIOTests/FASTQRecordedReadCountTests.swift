// FASTQRecordedReadCountTests.swift - A count recorded at import is bound to its file's size, and a cancel decides nothing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Row READ-LAYOUT-PARTIAL-SCAN, items 8 and 11. The sidecars here are written as JSON, the form on disk.
final class FASTQRecordedReadCountTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "recorded-read-count")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func size(of url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    /// Writes a sidecar with a recorded count and, for a mixed count, the L3 roles of `readClassification`.
    private func writeSidecar(for fastq: URL, r1: Int, r2: Int, unpaired: Int, sizeBytes: Int) throws {
        var object: [String: Any] = [
            "recordedReadCount": ["paired_r1": r1, "paired_r2": r2, "unpaired": unpaired, "storedSizeBytes": sizeBytes],
        ]
        if unpaired > 0 {
            let name = fastq.lastPathComponent
            object["readClassification"] = ["files": [
                ["filename": name, "role": "paired_r1", "readCount": r1],
                ["filename": name, "role": "paired_r2", "readCount": r2],
                ["filename": name, "role": "unpaired", "readCount": unpaired],
            ]]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: FASTQMetadataStore.metadataURL(for: fastq))
    }

    /// The count of a file that was replaced under the same name is dropped, and the layout comes from a new scan.
    func testReplacedFileDropsItsCount() throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(40)], to: fastq)
        try writeSidecar(for: fastq, r1: 30, r2: 30, unpaired: 20, sizeBytes: try size(of: fastq) + 1)

        let classification = FASTQReadLayoutClassifier.classify(inputURL: fastq)

        XCTAssertEqual(classification.layout, .strictlyInterleaved, classification.reason)
        XCTAssertEqual(classification.matePairs, 40)
        XCTAssertFalse(classification.reason.contains("recorded at import"), "a scan says it was a scan: \(classification.reason)")
        XCTAssertNil(FASTQMetadataStore.load(for: fastq)?.readClassification, "the stale roles go with the count")
    }

    /// The other way round: a stale count of only pairs proves nothing about the file now under the name.
    func testReplacedFileCountOfPairsProvesNothing() throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(30), .singles(20)], to: fastq)
        try writeSidecar(for: fastq, r1: 40, r2: 40, unpaired: 0, sizeBytes: try size(of: fastq) + 1)

        let classification = FASTQReadLayoutClassifier.classify(inputURL: fastq)

        XCTAssertEqual(classification.layout, .mixedInterleaved, classification.reason)
        XCTAssertEqual(classification.matePairs, 30)
        XCTAssertEqual(classification.unpairedRecords, 20)
    }

    /// A count that still names the file's size is the one other proof of strict, so a bounded call takes it. The
    /// reason says the file was not read again (BIO review, should-fix 1).
    func testACountOfTheseBytesIsTakenWithoutAScan() throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(40)], to: fastq)
        try writeSidecar(for: fastq, r1: 40, r2: 40, unpaired: 0, sizeBytes: try size(of: fastq))

        let classification = FASTQReadLayoutClassifier.classify(inputURL: fastq, limit: 2)

        XCTAssertEqual(classification.layout, .strictlyInterleaved, classification.reason)
        XCTAssertEqual(classification.scannedRecords, 80)
        XCTAssertEqual(classification.matePairs, 40)
        XCTAssertTrue(classification.scannedWholeFile)
        XCTAssertTrue(classification.reason.contains("recorded at import"), classification.reason)
        XCTAssertTrue(classification.reason.contains("not read again"), classification.reason)
    }

    /// The count travels with the file, so a moved project keeps it.
    func testACountTravelsWithItsFile() throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(30), .singles(20)], to: fastq)
        try writeSidecar(for: fastq, r1: 30, r2: 30, unpaired: 20, sizeBytes: try size(of: fastq))
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let movedFASTQ = moved.appendingPathComponent("reads.fastq")
        try FileManager.default.moveItem(at: fastq, to: movedFASTQ)
        try FileManager.default.moveItem(
            at: FASTQMetadataStore.metadataURL(for: fastq), to: FASTQMetadataStore.metadataURL(for: movedFASTQ))

        let classification = FASTQReadLayoutClassifier.classify(inputURL: movedFASTQ, limit: 2)

        XCTAssertEqual(classification.layout, .mixedInterleaved, classification.reason)
        XCTAssertEqual(classification.scannedRecords, 80)
        XCTAssertTrue(classification.scannedWholeFile)
    }

    // MARK: - The strip on save (BIO review should-fix 3, QA should-fix 2)

    private func rawSidecar(of fastq: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FASTQMetadataStore.metadataURL(for: fastq))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func metadata(countingBytes sizeBytes: Int) -> PersistedFASTQMetadata {
        PersistedFASTQMetadata(
            recordedReadCount: FASTQRecordedReadCount(pairedR1: 40, pairedR2: 40, unpaired: 0, storedSizeBytes: Int64(sizeBytes)))
    }

    /// `save` is the second guard against a stale proof. A count copied from another file is not written.
    func testSaveDropsACountCopiedFromAnotherFile() throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(40)], to: fastq)

        FASTQMetadataStore.save(metadata(countingBytes: try size(of: fastq) + 1), for: fastq)

        XCTAssertNil(try rawSidecar(of: fastq)["recordedReadCount"])
    }

    func testSaveKeepsACountOfTheSameBytes() throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(40)], to: fastq)

        FASTQMetadataStore.save(metadata(countingBytes: try size(of: fastq)), for: fastq)

        let kept = try XCTUnwrap(try rawSidecar(of: fastq)["recordedReadCount"] as? [String: Any])
        XCTAssertEqual(kept["paired_r1"] as? Int, 40)
    }

    /// QA guessed that a save before the FASTQ is in place strips only the count. It writes nothing at all, so a writer
    /// that saves its sidecar first loses all of it, not only the count. The CLI import saves after the file is there.
    func testSaveBeforeTheFileExistsWritesNoSidecar() throws {
        let fastq = root.appendingPathComponent("not-yet.fastq")

        FASTQMetadataStore.save(metadata(countingBytes: 1_000), for: fastq)

        XCTAssertFalse(FileManager.default.fileExists(atPath: FASTQMetadataStore.metadataURL(for: fastq).path))
    }

    // MARK: - A cancelled scan (the first report's try? Finding)

    /// A cancel is no answer about the file. It must not read as a file with no records, which is single-end.
    func testACancelledScanIsNeverSingleEndOrStrict() async throws {
        let fastq = root.appendingPathComponent("large.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(70_000)], to: fastq)
        let classify = Task.detached { () -> FASTQReadLayoutClassification in
            withUnsafeCurrentTask { $0?.cancel() }
            return FASTQReadLayoutClassifier.classify(inputURL: fastq)
        }
        let classified = await classify.value
        XCTAssertEqual(classified.layout, .mixedInterleaved, classified.reason)
        XCTAssertFalse(classified.scannedWholeFile)
        XCTAssertTrue(classified.reason.contains("cancelled"), classified.reason)

        let hint: URL = root
        let resolve = Task.detached { () -> FASTQInputLayoutResolution in
            withUnsafeCurrentTask { $0?.cancel() }
            return FASTQInputLayoutResolver.resolve(fastqURL: fastq, metadataFrom: hint)
        }
        let resolved = await resolve.value
        XCTAssertEqual(resolved.layout, .mixedMergedAndPairs, resolved.reason)
        XCTAssertTrue(resolved.reason.contains("cancelled"), resolved.reason)
    }

    /// A file that cannot be read keeps its own words, so the fix above moves only a cancel.
    func testAnUnreadableFileKeepsItsWords() throws {
        let classification = FASTQReadLayoutClassifier.classify(inputURL: root.appendingPathComponent("gone.fastq"))
        XCTAssertEqual(classification.layout, .singleEnd)
        XCTAssertEqual(classification.reason, "No FASTQ records could be read.")
    }
}
