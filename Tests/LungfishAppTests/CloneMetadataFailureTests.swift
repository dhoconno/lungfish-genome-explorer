// CloneMetadataFailureTests.swift - Clone Metadata says which copies were not saved (METADATA-EDIT-READONLY, Phase 3.2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport

/// The sidebar's Clone Metadata command saved each target with `try?`, so a read-only volume lost the copy with no
/// words and the change notice went out as if it had worked. The save and the words are checked here on bundle folders
/// made read-only, with no alert opened.
@MainActor
final class CloneMetadataFailureTests: XCTestCase {
    private var root: URL!
    private var locked: [URL] = []

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "clone-metadata-failure")
    }

    override func tearDown() async throws {
        for url in locked {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        locked = []
        TestTempDirectory.cleanup(root)
    }

    private func makeBundle(_ name: String, readOnly: Bool = false) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        if readOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
            locked.append(bundle)
        }
        return bundle
    }

    private func source() -> FASTQSampleMetadata {
        var metadata = FASTQSampleMetadata(sampleName: "Source")
        metadata.sampleType = "Blood"
        return metadata
    }

    func testCloneThatCannotBeSavedNamesTheBundleAndStillCopiesToTheOthers() throws {
        let writable = try makeBundle("Writable")
        let readOnly = try makeBundle("Locked", readOnly: true)

        let failed = SidebarViewController.cloneMetadata(source(), to: [writable, readOnly])

        XCTAssertEqual(failed.map { $0.target.lastPathComponent }, ["Locked.lungfishfastq"])
        let written = FASTQBundleCSVMetadata.load(from: writable).map { FASTQSampleMetadata(from: $0, fallbackName: "Writable") }
        XCTAssertEqual(written?.sampleType, "Blood", "the writable target got the copy")
        XCTAssertEqual(written?.sampleName, "Writable", "each target keeps its own sample name")
        let report = try XCTUnwrap(SidebarViewController.cloneMetadataFailureReport(failed, of: 2), "a failed copy shows words")
        XCTAssertEqual(report.title, "Could not copy the metadata to Locked")
        XCTAssertTrue(report.whatHappened.contains("Locked"), report.whatHappened)
        XCTAssertTrue(report.whatHappened.contains("read-only or full"), report.whatHappened)
        XCTAssertTrue(report.whatHappened.contains("The other one got the copy"), report.whatHappened)
        XCTAssertTrue(report.nextStep.contains("then copy the metadata again"), report.nextStep)
        XCTAssertNotNil(report.details, "the error text goes behind Show Details")
    }

    func testCloneThatSavesEverywhereShowsNothing() throws {
        let first = try makeBundle("One")
        let second = try makeBundle("Two")

        let failed = SidebarViewController.cloneMetadata(source(), to: [first, second])

        XCTAssertTrue(failed.isEmpty)
        XCTAssertNil(SidebarViewController.cloneMetadataFailureReport(failed, of: 2), "a copy that worked shows no alert")
    }

    func testCloneThatFailsOnSeveralTargetsShowsOneReportNamingThemAll() throws {
        let one = try makeBundle("LockedOne", readOnly: true)
        let two = try makeBundle("LockedTwo", readOnly: true)
        let writable = try makeBundle("Writable")

        let failed = SidebarViewController.cloneMetadata(source(), to: [one, writable, two])

        XCTAssertEqual(failed.count, 2)
        let report = try XCTUnwrap(SidebarViewController.cloneMetadataFailureReport(failed, of: 3))
        XCTAssertEqual(report.title, "Could not copy the metadata to 2 of 3 samples")
        XCTAssertTrue(report.whatHappened.contains("LockedOne") && report.whatHappened.contains("LockedTwo"), report.whatHappened)
        XCTAssertFalse(report.whatHappened.contains("Writable"), "a target that got the copy is not named: \(report.whatHappened)")
        XCTAssertNotNil(report.details, "each bundle's error is behind Show Details")
    }
}
