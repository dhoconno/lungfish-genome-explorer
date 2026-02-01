// VersionHistoryTests.swift - Tests for VersionHistory
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

@MainActor
final class VersionHistoryTests: XCTestCase {

    // MARK: - Commit Tests

    func testCommit() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")

        let version = try history.commit(newSequence: "ATCGNNNATCG", message: "Added NNN")

        XCTAssertEqual(history.versionCount, 2)  // original + 1 commit
        XCTAssertEqual(history.currentVersionIndex, 1)
        XCTAssertEqual(history.currentSequence, "ATCGNNNATCG")
        XCTAssertEqual(version.message, "Added NNN")
    }

    func testCommitNoChangesThrows() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")

        XCTAssertThrowsError(try history.commit(newSequence: "ATCGATCG", message: "No change")) { error in
            guard case VersionError.noChanges = error else {
                XCTFail("Expected noChanges error")
                return
            }
        }
    }

    func testMultipleCommits() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")

        try history.commit(newSequence: "ATCGNNNATCG", message: "v1")
        try history.commit(newSequence: "ATCGNNNATCGAAA", message: "v2")
        try history.commit(newSequence: "GGGATCGNNNATCGAAA", message: "v3")

        XCTAssertEqual(history.versionCount, 4)  // original + 3 commits
        XCTAssertEqual(history.currentVersionIndex, 3)
        XCTAssertEqual(history.currentSequence, "GGGATCGNNNATCGAAA")
    }

    // MARK: - Navigation Tests

    func testCheckoutByIndex() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "VERSION1", message: "v1")
        try history.commit(newSequence: "VERSION2", message: "v2")

        let result = try history.checkout(at: 1)

        XCTAssertEqual(result, "VERSION1")
        XCTAssertEqual(history.currentVersionIndex, 1)
        XCTAssertEqual(history.currentSequence, "VERSION1")
    }

    func testCheckoutOriginal() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "CHANGED", message: "change")

        let result = try history.checkout(at: 0)

        XCTAssertEqual(result, "ATCGATCG")
        XCTAssertEqual(history.currentVersionIndex, 0)
    }

    func testCheckoutInvalidIndexThrows() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")

        XCTAssertThrowsError(try history.checkout(at: 100)) { error in
            guard case VersionError.invalidVersionIndex = error else {
                XCTFail("Expected invalidVersionIndex error")
                return
            }
        }
    }

    func testGoBack() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "VERSION1", message: "v1")
        try history.commit(newSequence: "VERSION2", message: "v2")

        let result = try history.goBack()

        XCTAssertEqual(result, "VERSION1")
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
    }

    func testGoForward() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "VERSION1", message: "v1")
        _ = try history.checkout(at: 0)

        let result = try history.goForward()

        XCTAssertEqual(result, "VERSION1")
    }

    func testGoBackAtOldestThrows() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")

        XCTAssertThrowsError(try history.goBack()) { error in
            guard case VersionError.atOldestVersion = error else {
                XCTFail("Expected atOldestVersion error")
                return
            }
        }
    }

    func testGoForwardAtNewestThrows() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")

        XCTAssertThrowsError(try history.goForward()) { error in
            guard case VersionError.atNewestVersion = error else {
                XCTFail("Expected atNewestVersion error")
                return
            }
        }
    }

    func testGoToLatest() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "V1", message: "v1")
        try history.commit(newSequence: "V2", message: "v2")
        try history.commit(newSequence: "V3", message: "v3")
        _ = try history.checkout(at: 0)

        let result = try history.goToLatest()

        XCTAssertEqual(result, "V3")
        XCTAssertEqual(history.currentVersionIndex, 3)
    }

    func testGoToOriginal() throws {
        let history = VersionHistory(originalSequence: "ORIGINAL")
        try history.commit(newSequence: "CHANGED", message: "change")

        let result = try history.goToOriginal()

        XCTAssertEqual(result, "ORIGINAL")
        XCTAssertEqual(history.currentVersionIndex, 0)
    }

    // MARK: - Branching (Commit After Checkout)

    func testCommitAfterCheckoutTruncatesHistory() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "V1", message: "v1")
        try history.commit(newSequence: "V2", message: "v2")
        try history.commit(newSequence: "V3", message: "v3")

        // Go back to v1
        _ = try history.checkout(at: 1)

        // Commit new version (should replace v2 and v3)
        try history.commit(newSequence: "V1-ALT", message: "alternate")

        XCTAssertEqual(history.versionCount, 3)  // original, v1, v1-alt
        XCTAssertEqual(history.currentSequence, "V1-ALT")
        XCTAssertFalse(history.canGoForward)
    }

    // MARK: - Diff Between Versions

    func testDiffBetweenVersions() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "ATCGNNNATCG", message: "v1")

        let diff = try history.diff(from: 0, to: 1)

        XCTAssertFalse(diff.isEmpty)
    }

    func testDiffForVersion() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "ATCGNNNATCG", message: "v1")

        let diff = history.diffForVersion(at: 1)

        XCTAssertNotNil(diff)
        XCTAssertFalse(diff!.isEmpty)
    }

    // MARK: - Persistence Tests

    func testJSONRoundTrip() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG", sequenceName: "test_seq")
        try history.commit(newSequence: "V1", message: "version 1")
        try history.commit(newSequence: "V2", message: "version 2")

        let json = try history.toJSON()
        let restored = try VersionHistory.fromJSON(json)

        XCTAssertEqual(restored.originalSequence, "ATCGATCG")
        XCTAssertEqual(restored.sequenceName, "test_seq")
        XCTAssertEqual(restored.versionCount, 3)
        XCTAssertEqual(restored.versions.count, 2)
    }

    // MARK: - Version Properties

    func testVersionHash() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        let version = try history.commit(newSequence: "CHANGED", message: "change")

        XCTAssertFalse(version.contentHash.isEmpty)
        XCTAssertEqual(version.shortHash.count, 8)
    }

    func testVersionSummaries() throws {
        let history = VersionHistory(originalSequence: "ATCGATCG")
        try history.commit(newSequence: "V1", message: "First change")
        try history.commit(newSequence: "V2", message: "Second change")

        let summaries = history.getVersionSummaries()

        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].message, "First change")
        XCTAssertEqual(summaries[1].message, "Second change")
    }
}
