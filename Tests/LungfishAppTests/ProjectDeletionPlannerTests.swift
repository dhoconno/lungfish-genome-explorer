// ProjectDeletionPlannerTests.swift - Dependency-aware sidebar deletion tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class ProjectDeletionPlannerTests: XCTestCase {
    private var tempDir: URL!
    private var projectURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectDeletionPlannerTests-\(UUID().uuidString)", isDirectory: true)
        projectURL = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testDeletionImpactFindsTransitiveVirtualFASTQAndAnalysisDependents() throws {
        let sourceBundleURL = projectURL.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: sourceBundleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )

        let derivedBundleURL = projectURL.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedBundleURL, withIntermediateDirectories: true)
        try """
        {
          "parentBundleRelativePath": "../source.lungfishfastq",
          "rootBundleRelativePath": "../source.lungfishfastq",
          "rootFASTQFilename": "reads.fastq"
        }
        """.write(
            to: derivedBundleURL.appendingPathComponent("derived.manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let analysisURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("mapping-20260521", isDirectory: true)
        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
        try """
        {"inputs":["\(derivedBundleURL.path)"],"tool":"minimap2"}
        """.write(
            to: analysisURL.appendingPathComponent("mapping-result.json"),
            atomically: true,
            encoding: .utf8
        )

        let impact = ProjectDeletionPlanner(fileManager: .default)
            .impact(ofDeleting: [sourceBundleURL], in: projectURL)

        XCTAssertEqual(
            impact.dependentURLs.map(\.standardizedFileURL),
            [derivedBundleURL, analysisURL].map(\.standardizedFileURL)
        )
        XCTAssertEqual(
            Set(impact.urlsForCascadingDeletion.map(\.standardizedFileURL)),
            Set([sourceBundleURL, derivedBundleURL, analysisURL].map(\.standardizedFileURL))
        )
    }

    func testDeletionImpactIgnoresSelectedItemsAndUnrelatedObjects() throws {
        let selectedURL = projectURL.appendingPathComponent("selected.lungfishfastq", isDirectory: true)
        let unrelatedURL = projectURL.appendingPathComponent("unrelated.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedURL, withIntermediateDirectories: true)
        try "{}".write(
            to: unrelatedURL.appendingPathComponent("derived.manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let impact = ProjectDeletionPlanner(fileManager: .default)
            .impact(ofDeleting: [selectedURL], in: projectURL)

        XCTAssertTrue(impact.dependentURLs.isEmpty)
        XCTAssertEqual(impact.urlsForCascadingDeletion.map(\.standardizedFileURL), [selectedURL.standardizedFileURL])
    }

    func testCompanionSidecarCleanupIncludesFASTQMetadataAndAppleDoubleFiles() throws {
        let bundleURL = projectURL.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let metadataURL = bundleURL.appendingPathExtension("lungfish-meta.json")
        let appleDoubleMetadataURL = projectURL.appendingPathComponent("._\(metadataURL.lastPathComponent)")
        let appleDoubleBundleURL = projectURL.appendingPathComponent("._\(bundleURL.lastPathComponent)")
        try "{}".write(to: metadataURL, atomically: true, encoding: .utf8)
        try "appledouble".write(to: appleDoubleMetadataURL, atomically: true, encoding: .utf8)
        try "appledouble".write(to: appleDoubleBundleURL, atomically: true, encoding: .utf8)

        let sidecars = ProjectDeletionPlanner(fileManager: .default)
            .existingCompanionSidecarURLs(for: bundleURL)

        XCTAssertEqual(
            Set(sidecars.map(\.standardizedFileURL)),
            Set([metadataURL, appleDoubleMetadataURL, appleDoubleBundleURL].map(\.standardizedFileURL))
        )
    }

    func testDependencyListPresentationTruncatesPreviewAndKeepsFullProjectRelativeList() throws {
        let dependentURLs = (1...5).map { index in
            projectURL
                .appendingPathComponent("Analyses", isDirectory: true)
                .appendingPathComponent("mapping-\(String(format: "%02d", index))", isDirectory: true)
        }

        let presentation = ProjectDeletionDependencyListPresentation(
            dependentURLs: dependentURLs,
            projectURL: projectURL,
            previewLimit: 3
        )

        XCTAssertTrue(presentation.isTruncated)
        XCTAssertEqual(presentation.previewLines, ["mapping-01", "mapping-02", "mapping-03"])
        XCTAssertEqual(presentation.overflowLine, "... and 2 more")
        XCTAssertEqual(
            presentation.fullListLines,
            [
                "Analyses/mapping-01",
                "Analyses/mapping-02",
                "Analyses/mapping-03",
                "Analyses/mapping-04",
                "Analyses/mapping-05",
            ]
        )
    }
}
