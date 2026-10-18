// ReferenceViewportIdentityTests.swift - What makes a shown reference or mapping a new version
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

/// The viewport keeps its state when a display request names the same
/// document at the same version, and it compares versions without the
/// per-sequence arrays. These tests pin two parts of that version.
@MainActor
final class ReferenceViewportIdentityTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        try await super.tearDown()
    }

    /// The manifest name titles the document and the table, so a rename that
    /// keeps the identifier and the date is still a new version.
    func testRenamedManifestAtTheSameVersionIsANewDocument() {
        let bundleURL = URL(fileURLWithPath: "/tmp/reference.lungfishref", isDirectory: true)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        func input(named name: String) -> ReferenceBundleViewportInput {
            .directBundle(
                bundleURL: bundleURL,
                manifest: BundleManifest(
                    name: name,
                    identifier: "org.lungfish.test.reference",
                    modifiedDate: modified,
                    source: SourceInfo(organism: "Homo sapiens", assembly: "GRCh38")
                )
            )
        }

        XCTAssertEqual(input(named: "GRCh38"), input(named: "GRCh38"))
        XCTAssertNotEqual(input(named: "GRCh38"), input(named: "GRCh38 renamed"))
    }

    /// The open stamps the saved result before it decodes it. A rewrite while
    /// the decode runs then leaves the shown version older than the file, so
    /// the next open of the folder is not taken for the one on screen.
    func testMappingOpenStampsTheResultBeforeItsDecode() async throws {
        let root = try TestTempDirectory.make(prefix: "MappingOpenStamp")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Stamped", chromosomes: [.init(name: "chr1", length: 100)], in: root
        )
        let resultURL = root.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        try MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL
        ).save(to: resultURL)
        let resultFilePath = resultURL.appendingPathComponent("mapping-result.json").path
        let before = try XCTUnwrap(MappingResult.savedResultModificationDate(in: resultURL))
        let rewritten = before.addingTimeInterval(60)
        BundleLoadProbe.install { kind, _ in
            guard kind == .mappingResult else { return }
            try? FileManager.default.setAttributes([.modificationDate: rewritten], ofItemAtPath: resultFilePath)
        }

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayMappingAnalysisFromSidebar(at: resultURL)
        await split.bundleOpenTask?.value

        let input = try XCTUnwrap(split.viewerController.referenceBundleViewportController?.currentInput)
        XCTAssertEqual(input.mappingResultModificationDate, before)
        XCTAssertNotEqual(MappingResult.savedResultModificationDate(in: resultURL), before)
    }
}
