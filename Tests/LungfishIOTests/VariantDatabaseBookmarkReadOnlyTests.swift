// VariantDatabaseBookmarkReadOnlyTests.swift - A bookmark read never writes the variant database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.67 (decision MD32, BIO ruling BIO-CALLSDB-OPEN). The viewer opens every variant
// database of a displayed bundle read-write, and the drawer then asks each one for its bookmarked ids.
// That read created the `variant_bookmarks` table, so showing a bundle changed the bytes of
// `variants/calls.db` and a record's input digest of that file depended on whether the bundle had been
// viewed. Only a bookmark write may create the table.

import CryptoKit
import SQLite3
import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class VariantDatabaseBookmarkReadOnlyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "variant-bookmark-read-only")
    }

    override func tearDownWithError() throws {
        if let folder { TestTempDirectory.cleanup(folder) }
        folder = nil
    }

    /// The four reads the drawer and the exports make, on the read-write handle the viewer's search index holds.
    /// A fresh import has no bookmark table, so every read answers empty and none may add the table.
    func testBookmarkReadsOnAReadWriteHandleLeaveTheFileByteIdentical() throws {
        let url = try makeCallsDatabase()
        let before = try Self.sha256(of: url)
        XCTAssertFalse(try Self.tableNames(in: url).contains("variant_bookmarks"), "A fresh import holds no bookmark table.")

        do {
            let database = try VariantDatabase(url: url, readWrite: true)
            XCTAssertFalse(database.isBookmarked(variantId: 1))
            XCTAssertTrue(database.bookmarkedVariantIds().isEmpty)
            XCTAssertTrue(database.allBookmarks().isEmpty)
            XCTAssertTrue(database.bookmarkedVariants().isEmpty)
        }

        XCTAssertEqual(
            try Self.sha256(of: url), before,
            "A bookmark read on a read-write handle changed the bytes of the calls database."
        )
        XCTAssertFalse(
            try Self.tableNames(in: url).contains("variant_bookmarks"),
            "A bookmark read created the variant_bookmarks table."
        )
    }

    /// A bookmark write is the one thing that creates the table, and what it writes persists.
    func testToggleBookmarkCreatesTheTableAndPersists() throws {
        let url = try makeCallsDatabase()
        XCTAssertFalse(try Self.tableNames(in: url).contains("variant_bookmarks"), "A fresh import holds no bookmark table.")

        do {
            let writer = try VariantDatabase(url: url, readWrite: true)
            XCTAssertTrue(writer.toggleBookmark(variantId: 1), "The first toggle bookmarks the variant.")
            XCTAssertTrue(writer.isBookmarked(variantId: 1))
        }
        XCTAssertTrue(
            try Self.tableNames(in: url).contains("variant_bookmarks"),
            "A bookmark write creates the table."
        )

        do {
            let reader = try VariantDatabase(url: url)
            XCTAssertEqual(reader.bookmarkedVariantIds(), [1])
            XCTAssertEqual(reader.allBookmarks().map { $0.variantId }, [1])
            XCTAssertEqual(reader.bookmarkedVariants().count, 1)
        }

        do {
            let writer = try VariantDatabase(url: url, readWrite: true)
            XCTAssertFalse(writer.toggleBookmark(variantId: 1), "The second toggle removes the bookmark.")
        }
        let afterRemoval = try VariantDatabase(url: url)
        XCTAssertTrue(afterRemoval.bookmarkedVariantIds().isEmpty)
    }

    /// A read-only handle answers every bookmark read with none when the table is missing, and writes nothing.
    func testReadsOfADatabaseWithoutTheTableReturnNoBookmarksOnAReadOnlyHandle() throws {
        let url = try makeCallsDatabase()
        let before = try Self.sha256(of: url)

        do {
            let database = try VariantDatabase(url: url)
            XCTAssertFalse(database.isBookmarked(variantId: 1))
            XCTAssertTrue(database.bookmarkedVariantIds().isEmpty)
            XCTAssertTrue(database.allBookmarks().isEmpty)
            XCTAssertTrue(database.bookmarkedVariants().isEmpty)
        }

        XCTAssertEqual(try Self.sha256(of: url), before, "A read-only bookmark read changed the calls database.")
        XCTAssertFalse(try Self.tableNames(in: url).contains("variant_bookmarks"))
    }

    /// Removing a bookmark or its note where no bookmark table exists is a no-op that creates nothing.
    func testRemoveAndNoteOnADatabaseWithoutTheTableCreateNothing() throws {
        let url = try makeCallsDatabase()
        let before = try Self.sha256(of: url)

        do {
            let database = try VariantDatabase(url: url, readWrite: true)
            database.removeBookmark(variantId: 1)
            database.updateBookmarkNote(variantId: 1, note: "no bookmark here")
        }

        XCTAssertEqual(try Self.sha256(of: url), before, "Removing or annotating a missing bookmark changed the calls database.")
        XCTAssertFalse(try Self.tableNames(in: url).contains("variant_bookmarks"))
    }

    /// The table check asks again while the table is missing, so a bookmark that a second handle writes later is seen.
    func testAHandleThatReadBeforeTheTableExistedSeesABookmarkAnotherHandleToggles() throws {
        let url = try makeCallsDatabase()
        let reader = try VariantDatabase(url: url)
        XCTAssertTrue(reader.bookmarkedVariantIds().isEmpty, "No table yet, so no bookmarks.")

        let writer = try VariantDatabase(url: url, readWrite: true)
        XCTAssertTrue(writer.toggleBookmark(variantId: 1))

        XCTAssertEqual(reader.bookmarkedVariantIds(), [1], "The reader asks again and finds the table the writer made.")
        XCTAssertTrue(reader.isBookmarked(variantId: 1))
    }

    // MARK: - Helpers

    /// A calls database made by the importer from two variants and two samples.
    private func makeCallsDatabase() throws -> URL {
        let vcf = folder.appendingPathComponent("calls.vcf")
        try ([
            "##fileformat=VCFv4.2", "##contig=<ID=chr1,length=3000>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2",
            "chr1\t1151\t.\tA\tG\t50\tPASS\t.\tGT\t0/1\t1/1",
            "chr1\t1200\t.\tC\tT\t50\tPASS\t.\tGT\t0/0\t0/1",
        ].joined(separator: "\n") + "\n").write(to: vcf, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("calls.db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: url)
        return url
    }

    /// The SHA-256 of the file's bytes, as a record's input digest names it.
    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// The names in `sqlite_master`, read through a read-only connection that writes nothing.
    private static func tableNames(in url: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = handle else {
            sqlite3_close(handle)
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { names.append(String(cString: text)) }
        }
        return names
    }
}
