// FASTQMetadataSaveFailureTests.swift - A metadata edit that cannot be saved says so (METADATA-EDIT-READONLY, Phase 3.2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport

/// A person's edit of a read set's metadata on a read-only volume was lost with no words, and marked saved
/// (`FASTQMetadataSection.swift`, `performSave`). These tests make the bundle folder read-only and record the report
/// the section hands to its presenter, so no modal alert opens.
@MainActor
final class FASTQMetadataSaveFailureTests: XCTestCase {
    private var root: URL!
    private var locked: [URL] = []

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "metadata-save-failure")
    }

    override func tearDown() async throws {
        for url in locked {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        locked = []
        TestTempDirectory.cleanup(root)
    }

    /// A bundle whose metadata names `sampleName`, loaded into a section that records what it presents.
    private func makeSection(bundleName: String, sampleName: String) throws -> (
        section: FASTQMetadataSectionViewModel, bundle: URL, reports: ReportLog
    ) {
        let bundle = root.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FASTQBundleCSVMetadata.save(FASTQSampleMetadata(sampleName: sampleName).toLegacyCSV(), to: bundle)
        let section = FASTQMetadataSectionViewModel()
        let reports = ReportLog()
        section.saveFailurePresenter = { reports.items.append($0) }
        section.load(from: bundle)
        return (section, bundle, reports)
    }

    private func setWritable(_ writable: Bool, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
        if !writable { locked.append(url) }
    }

    @MainActor
    final class ReportLog {
        var items: [FailureReport] = []
    }

    func testMetadataEditThatCannotBeSavedShowsWords() throws {
        let made = try makeSection(bundleName: "Locked", sampleName: "Locked")
        made.section.metadata?.sampleType = "Blood"
        try setWritable(false, made.bundle)

        made.section.performSave()

        XCTAssertEqual(made.reports.items.count, 1, "the failed save shows one report")
        let report = try XCTUnwrap(made.reports.items.first)
        let words = report.whatHappened + " " + report.nextStep
        XCTAssertTrue(report.whatHappened.contains("Locked"), "the words name the bundle: \(report.whatHappened)")
        XCTAssertTrue(words.contains("read-only or full"), "the words name the likely cause: \(words)")
        XCTAssertTrue(report.nextStep.contains("make the edit again"), "the words say what to try: \(report.nextStep)")
        XCTAssertEqual(report.title, "Could not save the metadata edit")
        XCTAssertNotNil(report.details, "the error text goes behind Show Details")
    }

    func testFailedSaveKeepsLastSavedAndSkipsOnSave() throws {
        let made = try makeSection(bundleName: "Held", sampleName: "Held")
        var saved: [FASTQSampleMetadata] = []
        made.section.onSave = { _, metadata in saved.append(metadata) }
        made.section.metadata?.sampleType = "Blood"
        made.section.performSave()
        XCTAssertEqual(saved.count, 1, "a save that works tells its listeners")
        XCTAssertTrue(made.reports.items.isEmpty, "a save that works shows nothing")

        try setWritable(false, made.bundle)
        made.section.metadata?.sampleType = "Saliva"
        made.section.performSave()
        XCTAssertEqual(saved.count, 1, "a save that failed tells no listener it worked")
        made.section.revertToLastSaved()
        XCTAssertEqual(made.section.metadata?.sampleType, "Blood", "Revert returns to the last edit that reached the disk")

        made.section.metadata?.sampleType = "Plasma"
        made.section.performSave()
        XCTAssertEqual(made.reports.items.count, 1, "autosave tries again after each pause, and one report stands until a save works")

        try setWritable(true, made.bundle)
        made.section.performSave()
        XCTAssertEqual(saved.count, 2, "the save that works tells its listeners")
        let onDisk = FASTQBundleCSVMetadata.load(from: made.bundle).map { FASTQSampleMetadata(from: $0, fallbackName: "Held") }
        XCTAssertEqual(onDisk?.sampleType, "Plasma", "the edit reached the disk")
        try setWritable(false, made.bundle)
        made.section.metadata?.sampleType = "Serum"
        made.section.performSave()
        XCTAssertEqual(made.reports.items.count, 2, "a failure after a save that worked is reported again")
    }

    func testAnEditWaitingForItsAutosaveShowsWordsWhenTheSectionMovesOn() throws {
        let made = try makeSection(bundleName: "Waiting", sampleName: "Waiting")
        made.section.metadata?.sampleType = "Blood"
        XCTAssertTrue(made.section.hasUnsavedChanges, "the edit waits for its autosave")
        try setWritable(false, made.bundle)

        made.section.clear()

        XCTAssertEqual(made.reports.items.count, 1, "the flush at selection time shows the same words")
        XCTAssertTrue(made.reports.items.first?.whatHappened.contains("Waiting") == true)
    }
}
