// LungfishFormattersTests.swift - Unit tests for LungfishFormatters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

@testable import LungfishCore
import XCTest

/// Unit tests for the shared byte/count/duration formatting helpers
/// consolidated in `LungfishFormatters` (repo audit findings F44/F45/F46).
final class LungfishFormattersTests: XCTestCase {

    // MARK: - formatBytes

    func testFormatBytesKB() {
        let result = LungfishFormatters.formatBytes(Int64(512))
        XCTAssertTrue(result.contains("bytes"), "Expected bytes, got: \(result)")
    }

    func testFormatBytesAboveKBThreshold() {
        let result = LungfishFormatters.formatBytes(Int64(2_048))
        XCTAssertTrue(result.contains("KB"), "Expected KB, got: \(result)")
    }

    func testFormatBytesMB() {
        let fiveMB: Int64 = 5 * 1024 * 1024
        let result = LungfishFormatters.formatBytes(fiveMB)
        XCTAssertTrue(result.contains("MB"), "Expected MB, got: \(result)")
    }

    func testFormatBytesGB() {
        let twoGB: Int64 = 2 * 1024 * 1024 * 1024
        let result = LungfishFormatters.formatBytes(twoGB)
        XCTAssertTrue(result.contains("GB"), "Expected GB, got: \(result)")
    }

    func testFormatBytesZero() {
        let result = LungfishFormatters.formatBytes(Int64(0))
        XCTAssertTrue(result.contains("Zero") || result.contains("0"), "Expected zero-byte label, got: \(result)")
    }

    func testFormatBytesUInt64Overload() {
        let fiveMB: UInt64 = 5 * 1024 * 1024
        let result = LungfishFormatters.formatBytes(fiveMB)
        XCTAssertTrue(result.contains("MB"), "Expected MB, got: \(result)")
    }

    /// Regression test for the F44-F46 consolidation (task 7): the CLI's
    /// former private `formatBytes` in `CondaCommand` used a fixed `%.1f`
    /// decimal (e.g. "2.1 GB" for 2_147_483_647 bytes). The canonical
    /// `ByteCountFormatter`-backed implementation uses adaptive
    /// significant-digit precision and renders the same input as "2.15 GB".
    /// This pins the canonical (now sole) behavior so the difference is not
    /// silently reintroduced.
    func testFormatBytesAdaptivePrecisionNearGBBoundary() {
        let result = LungfishFormatters.formatBytes(Int64(2_147_483_647))
        XCTAssertEqual(result, "2.15 GB", "Expected adaptive-precision GB rendering, got: \(result)")
    }

    // MARK: - formatGroupedCount

    func testFormatGroupedCountAddsThousandsSeparators() {
        XCTAssertEqual(LungfishFormatters.formatGroupedCount(1_234), "1,234")
    }

    func testFormatGroupedCountSmallValue() {
        XCTAssertEqual(LungfishFormatters.formatGroupedCount(42), "42")
    }

    // MARK: - formatAbbreviatedCount

    func testFormatAbbreviatedCountUnderThousand() {
        XCTAssertEqual(LungfishFormatters.formatAbbreviatedCount(42), "42")
    }

    func testFormatAbbreviatedCountThousands() {
        XCTAssertEqual(LungfishFormatters.formatAbbreviatedCount(1_234), "1.2K")
    }

    func testFormatAbbreviatedCountMillions() {
        XCTAssertEqual(LungfishFormatters.formatAbbreviatedCount(3_456_789), "3.5M")
    }

    func testFormatAbbreviatedCountInt64Overload() {
        XCTAssertEqual(LungfishFormatters.formatAbbreviatedCount(Int64(1_234)), "1.2K")
    }

    // MARK: - formatDuration

    func testFormatDurationLessThanOneSecond() {
        XCTAssertEqual(LungfishFormatters.formatDuration(0.5), "<1s")
    }

    func testFormatDurationOneSecond() {
        XCTAssertEqual(LungfishFormatters.formatDuration(1.0), "1s")
    }

    func testFormatDurationSeconds() {
        XCTAssertEqual(LungfishFormatters.formatDuration(42.0), "42s")
    }

    func testFormatDurationMinutesAndSeconds() {
        XCTAssertEqual(LungfishFormatters.formatDuration(192.7), "3m 12s")
    }

    func testFormatDurationExactMinute() {
        XCTAssertEqual(LungfishFormatters.formatDuration(60.0), "1m 0s")
    }

    func testFormatDurationHoursAndMinutes() {
        XCTAssertEqual(LungfishFormatters.formatDuration(4980.0), "1h 23m")
    }

    func testFormatDurationNegativeInterval() {
        XCTAssertEqual(LungfishFormatters.formatDuration(-5.0), "<1s")
    }

    func testFormatDurationZero() {
        XCTAssertEqual(LungfishFormatters.formatDuration(0.0), "<1s")
    }

    func testFormatDurationVeryLarge() {
        XCTAssertEqual(LungfishFormatters.formatDuration(86400.0), "24h 0m")
    }
}
