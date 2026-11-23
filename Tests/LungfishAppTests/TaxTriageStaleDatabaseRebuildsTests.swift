// TaxTriageStaleDatabaseRebuildsTests.swift - A stale TaxTriage database is rebuilt only where the project can be written (3.2 TTREADS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The set of tried databases is process-wide, so each test names a database of its own.

import XCTest
@testable import LungfishApp

@MainActor
final class TaxTriageStaleDatabaseRebuildsTests: XCTestCase {
    private func freshDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageStaleDatabaseRebuildsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("taxtriage.sqlite")
    }

    func testReadOnlyProjectIsNotRebuiltAndKeepsTheTry() {
        let database = freshDatabaseURL()
        XCTAssertFalse(TaxTriageStaleDatabaseRebuilds.shouldRebuild(readOnly: true, databaseURL: database), "a read-only project is never written")
        XCTAssertTrue(TaxTriageStaleDatabaseRebuilds.shouldRebuild(readOnly: false, databaseURL: database), "the try was kept for a writable open")
        XCTAssertFalse(TaxTriageStaleDatabaseRebuilds.shouldRebuild(readOnly: false, databaseURL: database), "one try a session")
    }

    func testNotShownMessageNamesTheResultAndTheCommand() {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("taxtriage-batch-2026-11-05T10-00-00")
        let words = TaxTriageStaleDatabaseRebuilds.notShownMessage(resultURL: result)
        XCTAssertTrue(words.contains(result.path), words)
        XCTAssertTrue(words.contains("build-db taxtriage"), words)
        XCTAssertTrue(words.contains("--force"), words)
    }

    /// TT-m2 BIO S-2. After TT-STRAIN-GROUP every database built before it is stale, and most of those read the right
    /// Reads, so the placeholder and the not-shown words give the reason that holds for them: the counts, on an
    /// organism with several references or strains. Red at the base.
    func testNotShownMessageNamesStrainsAsWellAsReferences() {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("taxtriage-batch-2026-11-23T10-00-00")
        let words = TaxTriageStaleDatabaseRebuilds.notShownMessage(resultURL: result)
        XCTAssertTrue(words.contains("or strains"), words)
    }

    func testRecountSubtitleSaysTheCountsNotTheReads() {
        XCTAssertTrue(TaxTriageStaleDatabaseRebuilds.recountSubtitle.contains("counts could read"), TaxTriageStaleDatabaseRebuilds.recountSubtitle)
    }
}
