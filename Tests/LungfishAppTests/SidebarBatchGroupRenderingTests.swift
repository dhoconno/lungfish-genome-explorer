// SidebarBatchGroupRenderingTests.swift - BG6 characterization/verification tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Verifies the sidebar's generic `buildBatchAnalysisNode` branch, previously
// dead code, now lights up correctly for the new N>1 fan-out producers
// (mapping/assembly write per-sample subdirectories; Savont writes flat
// `.fasta` files). See docs/superpowers/specs/2026-08-09-batch-results-grouping-design.md §5.

import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class SidebarBatchGroupRenderingTests: XCTestCase {

    private var tempRoot: URL!
    private var projectURL: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBatchGroupRendering-\(UUID().uuidString)", isDirectory: true)
        tempRoot = root
        projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    // MARK: - Directory-child batch (mapping/assembly shape)

    /// A `spades-batch-*` fixture directory (metadata isBatch:true + two
    /// per-sample subdirectories) must render as an expandable batchGroup
    /// with two children named by sample.
    func testDirectoryBackedBatchRendersExpandableGroupWithSampleChildren() throws {
        let batchDir = try AnalysesFolder.createAnalysisDirectory(
            tool: "spades",
            in: projectURL,
            isBatch: true,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sampleA = try AnalysesFolder.batchSampleDirectory(named: "SampleAlpha", in: batchDir)
        try "contig".write(to: sampleA.appendingPathComponent("contigs.fasta"), atomically: true, encoding: .utf8)
        let sampleB = try AnalysesFolder.batchSampleDirectory(named: "SampleBeta", in: batchDir)
        try "contig".write(to: sampleB.appendingPathComponent("contigs.fasta"), atomically: true, encoding: .utf8)

        guard let info = AnalysesFolder.analysisInfo(for: batchDir) else {
            return XCTFail("Expected batch directory to be recognized as an analysis directory")
        }
        XCTAssertTrue(info.isBatch)

        guard let node = SidebarProjectScanner.buildAnalysisNode(info: info) else {
            return XCTFail("Expected a batch group node")
        }

        XCTAssertEqual(node.type, .batchGroup)
        XCTAssertEqual(node.children.count, 2)
        XCTAssertEqual(node.children.map(\.title).sorted(), ["SampleAlpha", "SampleBeta"])
        for child in node.children {
            XCTAssertEqual(child.type, .analysisResult)
            XCTAssertEqual(child.userInfo["sampleId"], child.title)
        }
        XCTAssertEqual(node.subtitle, "2 samples")
    }

    // MARK: - Flat-file batch (Savont shape)

    /// A `savont-batch-*` fixture directory with two `.fasta` FILES (no
    /// subdirectories) must render two children, one per file. This is the
    /// gap `appendBatchChildrenFromFilesystem` must be fixed to close: it
    /// previously only enumerated directory children.
    func testFileBackedBatchRendersChildrenForFlatFiles() throws {
        let batchDir = try AnalysesFolder.createAnalysisDirectory(
            tool: "savont",
            in: projectURL,
            isBatch: true,
            date: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let fileA = AnalysesFolder.batchSampleFileURL(named: "SampleAlpha", extension: "fasta", in: batchDir)
        try ">seq\nACGT\n".write(to: fileA, atomically: true, encoding: .utf8)
        let fileB = AnalysesFolder.batchSampleFileURL(named: "SampleBeta", extension: "fasta", in: batchDir)
        try ">seq\nACGT\n".write(to: fileB, atomically: true, encoding: .utf8)

        guard let info = AnalysesFolder.analysisInfo(for: batchDir) else {
            return XCTFail("Expected batch directory to be recognized as an analysis directory")
        }
        XCTAssertTrue(info.isBatch)

        guard let node = SidebarProjectScanner.buildAnalysisNode(info: info) else {
            return XCTFail("Expected a batch group node for flat-file batch children")
        }

        XCTAssertEqual(node.type, .batchGroup)
        XCTAssertEqual(node.children.count, 2, "Flat .fasta file children must be enumerated, not skipped")
        XCTAssertEqual(node.children.map(\.title).sorted(), ["SampleAlpha.fasta", "SampleBeta.fasta"])
        for child in node.children {
            XCTAssertEqual(child.url?.lastPathComponent, child.title)
            XCTAssertEqual(child.userInfo["sampleId"], child.title)
        }
        XCTAssertEqual(node.subtitle, "2 samples")
    }

    /// `analysis-metadata.json` itself must never be surfaced as a batch child,
    /// whether the batch is directory-backed or file-backed.
    func testMetadataSidecarIsNeverSurfacedAsABatchChild() throws {
        let batchDir = try AnalysesFolder.createAnalysisDirectory(
            tool: "savont",
            in: projectURL,
            isBatch: true,
            date: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let fileA = AnalysesFolder.batchSampleFileURL(named: "SampleAlpha", extension: "fasta", in: batchDir)
        try ">seq\nACGT\n".write(to: fileA, atomically: true, encoding: .utf8)

        guard let info = AnalysesFolder.analysisInfo(for: batchDir) else {
            return XCTFail("Expected batch directory to be recognized as an analysis directory")
        }
        guard let node = SidebarProjectScanner.buildAnalysisNode(info: info) else {
            return XCTFail("Expected a batch group node")
        }

        XCTAssertFalse(
            node.children.contains { $0.title == AnalysesFolder.metadataFilename },
            "analysis-metadata.json must not appear as a batch child"
        )
        XCTAssertEqual(node.children.count, 1)
    }

    // MARK: - Regression pin: single-run directories unaffected

    /// A single-run `spades-<ts>` directory (isBatch:false) must render
    /// exactly as today: a plain analysis node, not a batch group, with no
    /// children synthesized from the filesystem.
    func testSingleRunDirectoryRendersAsPlainAnalysisNodeUnaffected() throws {
        let runDir = try AnalysesFolder.createAnalysisDirectory(
            tool: "spades",
            in: projectURL,
            isBatch: false,
            date: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try "contig".write(to: runDir.appendingPathComponent("contigs.fasta"), atomically: true, encoding: .utf8)

        guard let info = AnalysesFolder.analysisInfo(for: runDir) else {
            return XCTFail("Expected single-run directory to be recognized as an analysis directory")
        }
        XCTAssertFalse(info.isBatch)

        guard let node = SidebarProjectScanner.buildAnalysisNode(info: info) else {
            return XCTFail("Expected a plain analysis node")
        }

        XCTAssertNotEqual(node.type, .batchGroup)
        XCTAssertTrue(node.children.isEmpty, "Single-run nodes must not synthesize children")
        XCTAssertEqual(node.title, runDir.lastPathComponent)
    }
}
