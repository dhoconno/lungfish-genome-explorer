// GenotypeAnnotationRecoveryCopyTests.swift - A reader takes annotations.json from its recovery copy without renaming it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

/// Plan decision P9. A reader that finds `annotations.json` missing, or holding
/// only the empty reservation of an interrupted ExFAT rename, beside a
/// tombstone reads the newest tombstone that holds bytes in memory, renames
/// nothing and prints one warning line that names the recovery copy.
final class GenotypeAnnotationRecoveryCopyTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        let root = try TestTempDirectory.make(prefix: "genotype-recovery-copy")
        bundleURL = root.appendingPathComponent("P.lungfish/Analyses/Result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    func testAMissingSidecarIsReadFromItsNewestTombstoneWithoutRenaming() throws {
        try tombstone("older", modified: Date(timeIntervalSinceNow: -3600))
        let newest = try tombstone("newest", modified: Date())
        let before = try names()

        let (snapshot, lines) = try readCapturingNotices()

        XCTAssertEqual(snapshot.sidecar.sampleNotes.map(\.body), ["newest"])
        XCTAssertEqual(snapshot.data, try Data(contentsOf: bundleURL.appendingPathComponent(newest)))
        XCTAssertEqual(snapshot.revision, .sha256(sha256(try Data(contentsOf: bundleURL.appendingPathComponent(newest)))))
        XCTAssertEqual(try names(), before, "a read renames nothing")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("is missing") == true, lines.joined())
        XCTAssertTrue(lines.first?.contains("recovery copy \(newest)") == true, lines.joined())
        XCTAssertTrue(lines.first?.contains("Opening the result in Lungfish Genome Explorer restores the file") == true, lines.joined())
    }

    func testAnEmptyReservationGivesWayToTheTombstone() throws {
        let copy = try tombstone("kept", modified: Date())
        try Data().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let before = try names()

        let (snapshot, lines) = try readCapturingNotices()

        XCTAssertEqual(snapshot.sidecar.sampleNotes.map(\.body), ["kept"])
        XCTAssertEqual(try names(), before, "a read renames nothing")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("is empty") == true, lines.joined())
        XCTAssertTrue(lines.first?.contains(copy) == true, lines.joined())
        XCTAssertEqual(
            try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL).sampleNotes.map(\.body),
            ["kept"],
            "the read-only loader takes the copy too"
        )
    }

    /// `genotype export` reads the sidecar twice in one run, and the analyst
    /// sees the line once.
    func testTwoReadsOfOneBundleGiveOneLine() throws {
        try tombstone("kept", modified: Date())
        let lines = Lines()

        let bodies = try GenotypeAnnotationRecoveryCopy.$noticeSink.withValue({ lines.append($0) }) {
            try (0..<2).map { _ in
                try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(forBundleAt: bundleURL).sidecar.sampleNotes.map(\.body)
            }
        }

        XCTAssertEqual(bodies, [["kept"], ["kept"]], "each read takes the copy")
        XCTAssertEqual(lines.all.count, 1, lines.all.joined(separator: "\n"))
    }

    func testASidecarThatHoldsBytesIsReadAsItIsWithoutAWarning() throws {
        try tombstone("retired", modified: Date())
        var current = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        current.sampleNotes = [.init(sample: "S1", body: "current", author: "analyst", timestamp: "2026-10-11T00:00:00Z")]
        try current.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let (snapshot, lines) = try readCapturingNotices()

        XCTAssertEqual(snapshot.sidecar.sampleNotes.map(\.body), ["current"])
        XCTAssertEqual(lines, [])
    }

    func testNoTombstoneReadsAsAbsentWithoutAWarning() throws {
        let (snapshot, lines) = try readCapturingNotices()

        XCTAssertEqual(snapshot.revision, .absent)
        XCTAssertNil(snapshot.data)
        XCTAssertEqual(lines, [])
    }

    // MARK: - Helpers

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        func append(_ line: String) { lock.withLock { stored.append(line) } }
    }

    private func readCapturingNotices() throws -> (GenotypeAnnotationSidecarSnapshot, [String]) {
        let lines = Lines()
        let snapshot = try GenotypeAnnotationRecoveryCopy.$noticeSink.withValue({ lines.append($0) }) {
            try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(forBundleAt: bundleURL)
        }
        return (snapshot, lines.all)
    }

    @discardableResult
    private func tombstone(_ body: String, modified: Date) throws -> String {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        sidecar.sampleNotes = [.init(sample: "S1", body: body, author: "analyst", timestamp: "2026-10-11T00:00:00Z")]
        let name = ".\(GenotypeAnnotationSidecar.filename)\(PortableRename.swapTombstoneInfix)\(UUID().uuidString)"
        let url = bundleURL.appendingPathComponent(name)
        try sidecar.encoded().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return name
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bundleURL.path).sorted()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
