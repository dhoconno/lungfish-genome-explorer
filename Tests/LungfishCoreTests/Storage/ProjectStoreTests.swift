// ProjectStoreTests.swift - Tests for SQLite-based project storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishCore

@MainActor
final class ProjectStoreTests: XCTestCase {

    var tempDirectory: URL!
    var store: ProjectStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTests-\(UUID().uuidString)")
        store = try ProjectStore(at: tempDirectory)
    }

    override func tearDown() async throws {
        store = nil
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Sequence Tests

    func testStoreSequence() throws {
        let sequenceId = try store.storeSequence(
            name: "test_sequence",
            content: "ATCGATCGATCG",
            alphabet: "dna"
        )

        XCTAssertNotNil(sequenceId)

        let retrieved = try store.getSequence(id: sequenceId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.name, "test_sequence")
        XCTAssertEqual(retrieved?.originalContent, "ATCGATCGATCG")
        XCTAssertEqual(retrieved?.alphabet, "dna")
        XCTAssertEqual(retrieved?.length, 12)
    }

    func testStoreSequenceWithMetadata() throws {
        let metadata = ["organism": "E. coli", "strain": "K-12"]
        let sequenceId = try store.storeSequence(
            name: "ecoli_gene",
            content: "ATGCCCGGG",
            alphabet: "dna",
            metadata: metadata
        )

        let retrieved = try store.getSequence(id: sequenceId)
        XCTAssertEqual(retrieved?.metadata?["organism"], "E. coli")
        XCTAssertEqual(retrieved?.metadata?["strain"], "K-12")
    }

    func testListSequences() throws {
        try store.storeSequence(name: "seq1", content: "ATCG")
        try store.storeSequence(name: "seq2", content: "GCTA")
        try store.storeSequence(name: "seq3", content: "TTTT")

        let sequences = try store.listSequences()
        XCTAssertEqual(sequences.count, 3)

        let names = sequences.map(\.name).sorted()
        XCTAssertEqual(names, ["seq1", "seq2", "seq3"])
    }

    // MARK: - Version Tests

    func testRecordVersion() throws {
        let sequenceId = try store.storeSequence(
            name: "versioned_seq",
            content: "ATCGATCG"
        )

        // Create a diff
        let diff = SequenceDiff.compute(from: "ATCGATCG", to: "ATCGGGGATCG")
        let newHash = "abc123" // Simplified hash for testing

        let versionId = try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff,
            newContentHash: newHash,
            message: "Added GGG insertion",
            author: "Test"
        )

        XCTAssertNotNil(versionId)

        let history = try store.getVersionHistory(for: sequenceId)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].message, "Added GGG insertion")
        XCTAssertEqual(history[0].author, "Test")
    }

    func testMultipleVersions() throws {
        let sequenceId = try store.storeSequence(
            name: "multi_version",
            content: "AAAA"
        )

        // Version 1: AAAA -> AAGG
        let diff1 = SequenceDiff.compute(from: "AAAA", to: "AAGG")
        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff1,
            newContentHash: "hash1",
            message: "Change 1"
        )

        // Version 2: AAGG -> GGGG
        let diff2 = SequenceDiff.compute(from: "AAGG", to: "GGGG")
        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff2,
            newContentHash: "hash2",
            message: "Change 2"
        )

        let history = try store.getVersionHistory(for: sequenceId)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].message, "Change 1")
        XCTAssertEqual(history[1].message, "Change 2")
    }

    func testReconstructSequence() throws {
        let sequenceId = try store.storeSequence(
            name: "reconstruct_test",
            content: "AAAA"
        )

        // Version 1: AAAA -> AABB
        let diff1 = SequenceDiff.compute(from: "AAAA", to: "AABB")
        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff1,
            newContentHash: "hash1"
        )

        // Version 2: AABB -> AABBCC
        let diff2 = SequenceDiff.compute(from: "AABB", to: "AABBCC")
        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff2,
            newContentHash: "hash2"
        )

        // Reconstruct at different versions
        let v0 = try store.reconstructSequence(id: sequenceId, atVersion: 0)
        XCTAssertEqual(v0, "AAAA")

        let v1 = try store.reconstructSequence(id: sequenceId, atVersion: 1)
        XCTAssertEqual(v1, "AABB")

        let v2 = try store.reconstructSequence(id: sequenceId, atVersion: 2)
        XCTAssertEqual(v2, "AABBCC")
    }

    func testCheckoutVersion() throws {
        let sequenceId = try store.storeSequence(
            name: "checkout_test",
            content: "AAAA"
        )

        let diff = SequenceDiff.compute(from: "AAAA", to: "BBBB")
        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff,
            newContentHash: "hash1"
        )

        // Verify we're at version 1
        var currentIndex = try store.getCurrentVersionIndex(for: sequenceId)
        XCTAssertEqual(currentIndex, 1)

        // Checkout version 0
        try store.checkoutVersion(sequenceId: sequenceId, versionIndex: 0)
        currentIndex = try store.getCurrentVersionIndex(for: sequenceId)
        XCTAssertEqual(currentIndex, 0)

        // Checkout version 1 again
        try store.checkoutVersion(sequenceId: sequenceId, versionIndex: 1)
        currentIndex = try store.getCurrentVersionIndex(for: sequenceId)
        XCTAssertEqual(currentIndex, 1)
    }

    // MARK: - Edit Log Tests

    func testLogEdit() throws {
        let sequenceId = try store.storeSequence(
            name: "edit_log_test",
            content: "ATCG"
        )

        try store.logEdit(
            sequenceId: sequenceId,
            operation: "insert",
            position: 2,
            length: nil,
            bases: "GGG",
            sessionId: "test-session"
        )

        let edits = try store.getRecentEdits(sequenceId: sequenceId)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].operation, "insert")
        XCTAssertEqual(edits[0].position, 2)
        XCTAssertEqual(edits[0].bases, "GGG")
        XCTAssertEqual(edits[0].sessionId, "test-session")
    }

    func testRecentEditsLimit() throws {
        let sequenceId = try store.storeSequence(
            name: "edit_limit_test",
            content: "ATCG"
        )

        // Log 10 edits
        for i in 0..<10 {
            try store.logEdit(
                sequenceId: sequenceId,
                operation: "edit_\(i)",
                position: i,
                length: nil,
                bases: nil,
                sessionId: nil
            )
        }

        // Get only 5 recent edits
        let edits = try store.getRecentEdits(sequenceId: sequenceId, limit: 5)
        XCTAssertEqual(edits.count, 5)

        // Should be in reverse chronological order
        XCTAssertEqual(edits[0].operation, "edit_9")
        XCTAssertEqual(edits[4].operation, "edit_5")
    }

    // MARK: - Annotation Tests

    func testStoreAnnotation() throws {
        let sequenceId = try store.storeSequence(
            name: "annotation_test",
            content: String(repeating: "ATCG", count: 100)
        )

        let annotationId = try store.storeAnnotation(
            sequenceId: sequenceId,
            type: "gene",
            name: "geneA",
            startPosition: 10,
            endPosition: 100,
            strand: "+",
            qualifiers: ["product": "Test protein"],
            color: "#FF0000"
        )

        XCTAssertNotNil(annotationId)

        let annotations = try store.getAnnotations(sequenceId: sequenceId)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].type, "gene")
        XCTAssertEqual(annotations[0].name, "geneA")
        XCTAssertEqual(annotations[0].startPosition, 10)
        XCTAssertEqual(annotations[0].endPosition, 100)
        XCTAssertEqual(annotations[0].strand, "+")
        XCTAssertEqual(annotations[0].qualifiers?["product"], "Test protein")
        XCTAssertEqual(annotations[0].color, "#FF0000")
    }

    func testGetAnnotationsInRange() throws {
        let sequenceId = try store.storeSequence(
            name: "range_test",
            content: String(repeating: "ATCG", count: 250)
        )

        // Add annotations at different positions
        try store.storeAnnotation(
            sequenceId: sequenceId,
            type: "gene",
            name: "gene1",
            startPosition: 0,
            endPosition: 100
        )

        try store.storeAnnotation(
            sequenceId: sequenceId,
            type: "gene",
            name: "gene2",
            startPosition: 200,
            endPosition: 300
        )

        try store.storeAnnotation(
            sequenceId: sequenceId,
            type: "gene",
            name: "gene3",
            startPosition: 500,
            endPosition: 600
        )

        // Query range 150-400 (should include gene2)
        let annotations = try store.getAnnotations(
            sequenceId: sequenceId,
            inRange: 150..<400
        )

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].name, "gene2")
    }

    // MARK: - Project Metadata Tests

    func testProjectMetadata() throws {
        try store.setMetadata(key: "project_name", value: "Test Project")
        try store.setMetadata(key: "organism", value: "E. coli")

        XCTAssertEqual(try store.getMetadata(key: "project_name"), "Test Project")
        XCTAssertEqual(try store.getMetadata(key: "organism"), "E. coli")
        XCTAssertNil(try store.getMetadata(key: "nonexistent"))

        // Update existing key
        try store.setMetadata(key: "project_name", value: "Updated Name")
        XCTAssertEqual(try store.getMetadata(key: "project_name"), "Updated Name")
    }

    func testListSequencesParsesSQLiteTimestamps() throws {
        try store.storeSequence(name: "dated_sequence", content: "ATCG")
        try withRawDatabase { db in
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "UPDATE sequences SET created_at = '2024-01-02 03:04:05', modified_at = '2024-01-02T06:07:08Z'",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
        }

        let sequence = try XCTUnwrap(store.listSequences().first)

        XCTAssertEqual(sequence.createdAt, sqliteDate("2024-01-02 03:04:05"))
        XCTAssertEqual(sequence.modifiedAt, isoDate("2024-01-02T06:07:08Z"))
    }

    func testVersionHistoryParsesSQLiteTimestamps() throws {
        let sequenceId = try store.storeSequence(
            name: "versioned_dates",
            content: "AAAA"
        )
        let diff = SequenceDiff.compute(from: "AAAA", to: "AAAT")
        try store.recordVersion(
            sequenceId: sequenceId,
            diff: diff,
            newContentHash: Version.computeHash("AAAT")
        )
        try withRawDatabase { db in
            XCTAssertEqual(
                sqlite3_exec(
                    db,
                    "UPDATE versions SET created_at = '2024-02-03 04:05:06'",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
        }

        let version = try XCTUnwrap(store.getVersionHistory(for: sequenceId).first)
        XCTAssertEqual(version.createdAt, sqliteDate("2024-02-03 04:05:06"))
    }

    private func withRawDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        let dbURL = tempDirectory.appendingPathComponent(".project.db")
        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            throw NSError(domain: "ProjectStoreTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        defer { sqlite3_close_v2(db) }
        try body(db)
    }

    private func sqliteDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func isoDate(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
