// AnalysisManifestTests.swift - Tests for AnalysisManifestStore
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class AnalysisManifestTests: XCTestCase {
    private var tempDir: URL!
    private var bundleDir: URL!
    private var projectDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-manifest-\(UUID().uuidString)")
        projectDir = tempDir
        bundleDir = tempDir.appendingPathComponent("sample.lungfishfastq")
        try! FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLoadReturnsEmptyForMissingFile() {
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 0)
    }

    func testLoadReturnsEmptyForCorruptFile() throws {
        let manifestURL = bundleDir.appendingPathComponent(AnalysisManifest.filename)
        try "{ broken json".write(to: manifestURL, atomically: true, encoding: .utf8)
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 0)
    }

    func testRecordAndLoad() throws {
        let entry = AnalysisManifestEntry(
            tool: "esviritu", analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu Detection",
            parameters: ["sampleName": .string("testSample")],
            summary: "2 viruses detected"
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleDir)
        // Create the analysis directory so pruning doesn't remove it
        let analysesDir = try AnalysesFolder.url(for: projectDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true)

        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 1)
        XCTAssertEqual(manifest.analyses.first?.tool, "esviritu")
        XCTAssertEqual(manifest.analyses.first?.summary, "2 viruses detected")
    }

    func testRecordAppendsToExisting() throws {
        let analysesDir = try AnalysesFolder.url(for: projectDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("kraken2-2026-01-15T11-00-00"),
            withIntermediateDirectories: true)

        let entry1 = AnalysisManifestEntry(
            tool: "esviritu", analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu", summary: "first"
        )
        let entry2 = AnalysisManifestEntry(
            tool: "kraken2", analysisDirectoryName: "kraken2-2026-01-15T11-00-00",
            displayName: "Kraken2", summary: "second"
        )
        try AnalysisManifestStore.recordAnalysis(entry1, bundleURL: bundleDir)
        try AnalysisManifestStore.recordAnalysis(entry2, bundleURL: bundleDir)

        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 2)
    }

    func testRecordAnalysisRejectsCorruptExistingManifestWithoutOverwriting() throws {
        let manifestURL = bundleDir.appendingPathComponent(AnalysisManifest.filename)
        let corruptData = Data("{ broken json".utf8)
        try corruptData.write(to: manifestURL, options: .atomic)

        let entry = AnalysisManifestEntry(
            tool: "esviritu",
            analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu",
            summary: "should not overwrite corrupt history"
        )

        XCTAssertThrowsError(try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleDir))
        XCTAssertEqual(try Data(contentsOf: manifestURL), corruptData)
    }

    func testPruneRemovesStaleEntries() throws {
        let analysesDir = try AnalysesFolder.url(for: projectDir)
        let existingDir = analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00")
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        let good = AnalysisManifestEntry(
            tool: "esviritu", analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "EsViritu", summary: "exists"
        )
        let stale = AnalysisManifestEntry(
            tool: "kraken2", analysisDirectoryName: "kraken2-DOES-NOT-EXIST",
            displayName: "Kraken2", summary: "stale"
        )
        try AnalysisManifestStore.recordAnalysis(good, bundleURL: bundleDir)
        try AnalysisManifestStore.recordAnalysis(stale, bundleURL: bundleDir)

        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        XCTAssertEqual(manifest.analyses.count, 1)
        XCTAssertEqual(manifest.analyses.first?.tool, "esviritu")
    }

    func testParametersRoundTrip() throws {
        let analysesDir = try AnalysesFolder.url(for: projectDir)
        try FileManager.default.createDirectory(
            at: analysesDir.appendingPathComponent("esviritu-2026-01-15T10-00-00"),
            withIntermediateDirectories: true)

        let entry = AnalysisManifestEntry(
            tool: "esviritu", analysisDirectoryName: "esviritu-2026-01-15T10-00-00",
            displayName: "Test",
            parameters: [
                "sampleName": .string("SRR123"),
                "minReads": .int(10),
                "minCoverage": .double(1.5),
                "qualityFilter": .bool(true),
            ],
            summary: "test"
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleDir)
        let manifest = AnalysisManifestStore.load(bundleURL: bundleDir, projectURL: projectDir)
        let params = manifest.analyses.first!.parameters
        XCTAssertEqual(params["sampleName"]?.stringValue, "SRR123")
        XCTAssertEqual(params["minReads"]?.intValue, 10)
        XCTAssertEqual(params["minCoverage"]?.doubleValue, 1.5)
        XCTAssertEqual(params["qualityFilter"]?.boolValue, true)
    }
}
