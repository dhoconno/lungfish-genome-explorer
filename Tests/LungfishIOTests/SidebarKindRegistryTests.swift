// SidebarKindRegistryTests.swift - The facts of the one sidebar kind table (Phase 3.2 lane SIDEBAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The registry took over three prefix tables: the scanner's result-folder prefixes, the Inspector tab prefixes of an
// import and the deletion planner's two prefixes. These tests hold the answers those tables gave.

import Foundation
import XCTest
@testable import LungfishIO

final class SidebarKindRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-kind-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheLegacyPrefixesAreTheOnesTheOldTablesHeld() {
        let prefixes = Dictionary(uniqueKeysWithValues: SidebarKindRegistry.analysisKinds.compactMap { kind in
            kind.legacyFolder.map { (kind.id, $0.namePrefixes) }
        })
        XCTAssertEqual(prefixes, [
            "analysis:esviritu": ["esviritu-"],
            "analysis:kraken2": ["classification-", "kraken2-"],
            "analysis:taxtriage": ["taxtriage-"],
            "analysis:naomgs": ["naomgs-"],
            "analysis:nvd": ["nvd-"],
            "analysis:cz-id": ["cz-id-"],
        ])
    }

    func testOnlyTheFiveViewerSetTabKindsKeepTheirTabAndOnlyNaoMgsAndNvdAreDeletionAnalyses() {
        let viewerTab = Set(SidebarKindRegistry.all.filter { $0.inspectorTab == .setByViewer }.map(\.id))
        XCTAssertEqual(viewerTab, ["analysis:esviritu", "analysis:kraken2", "analysis:taxtriage",
                                   "analysis:naomgs", "analysis:nvd"])
        let deletion = Set(SidebarKindRegistry.all.filter(\.deletionTreatsLegacyFolderAsAnalysis).map(\.id))
        XCTAssertEqual(deletion, ["analysis:naomgs", "analysis:nvd"])
    }

    func testEveryKindHasAUniqueID() {
        let ids = SidebarKindRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testTheMetadataSidecarDecidesBeforeTheLegacyPrefix() throws {
        let folder = root.appendingPathComponent("nvd-renamed-esviritu", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertEqual(SidebarKindRegistry.analysisKind(ofFolder: folder)?.id, "analysis:nvd")

        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "esviritu", isBatch: false), to: folder)
        XCTAssertEqual(SidebarKindRegistry.analysisKind(ofFolder: folder)?.id, "analysis:esviritu")
    }

    func testTheFallbackNeedsAMarkerAndSkipsABundleFolder() throws {
        let noMarker = root.appendingPathComponent("taxtriage-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: noMarker, withIntermediateDirectories: true)
        XCTAssertNil(SidebarKindRegistry.legacyAnalysisKind(ofFolder: noMarker))

        try FileManager.default.createDirectory(
            at: noMarker.appendingPathComponent("kraken2", isDirectory: true), withIntermediateDirectories: true)
        XCTAssertEqual(SidebarKindRegistry.legacyAnalysisKind(ofFolder: noMarker)?.id, "analysis:taxtriage")

        let czIdBundle = root.appendingPathComponent("cz-id-sample.lungfishtax", isDirectory: true)
        try FileManager.default.createDirectory(at: czIdBundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: czIdBundle.appendingPathComponent("cz-id-manifest.json"))
        XCTAssertNil(SidebarKindRegistry.legacyAnalysisKind(ofFolder: czIdBundle))
        XCTAssertEqual(SidebarKindRegistry.bundleKind(ofFolder: czIdBundle)?.id, "bundle:\(BundleKindID.czIdResult.rawValue)")
    }

    func testACZIDBundleWithoutItsManifestIsNoKindAndAnMHCBundleNeedsNone() throws {
        let czId = root.appendingPathComponent("bare.LUNGFISHTAX", isDirectory: true)
        try FileManager.default.createDirectory(at: czId, withIntermediateDirectories: true)
        XCTAssertNil(SidebarKindRegistry.bundleKind(ofFolder: czId))
        let mhc = root.appendingPathComponent("bare.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: mhc, withIntermediateDirectories: true)
        XCTAssertEqual(SidebarKindRegistry.bundleKind(ofFolder: mhc)?.rowType, .mhcReferenceBundle)
    }

    func testARegisteredKindJoinsAndLeaves() {
        let bundle = BundleKindDescriptor(
            id: BundleKindID(rawValue: "registry-test"), role: .bundle, folderExtensions: ["lungfishregistrytest"],
            manifestFileName: nil, recognition: .extensionOnly, utTypeIdentifier: nil, sidebarSymbolName: "star",
            presentation: .atomicPackage, deletion: .init(isOpaqueProjectObject: true), copy: .refused,
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: [])
        let kind = SidebarKindDescriptor(
            id: "bundle:registry-test", recognition: .bundle(bundle, manifestRequired: false),
            rowType: .registeredBundle, sidebarSymbolName: "star", displayName: "Test", viewport: nil)
        let url = root.appendingPathComponent("a.lungfishregistrytest")
        XCTAssertNil(SidebarKindRegistry.bundleKind(ofFolder: url))
        SidebarKindRegistry.register(kind)
        defer { SidebarKindRegistry.unregister(id: kind.id) }
        XCTAssertEqual(SidebarKindRegistry.bundleKind(ofFolder: url)?.id, kind.id)
        XCTAssertEqual(SidebarKindRegistry.descriptor(id: kind.id), kind)
    }
}
