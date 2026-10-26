// AnnotationDrawerIndexHandoffTests.swift - The annotation drawer leaves its loading state when its index build ends
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane DRAWER (DRAWER-INDEX-HANDOFF, S2, UX ruling of the 2026-10-26 panel meeting). The annotation
// drawer shows "Building annotation index" until a search index reaches it. Two routes build that index, the
// bundle-display route (`ViewerViewController+BundleDisplay.swift`, the reload after an annotation change) and the
// window controller's `bundleDidLoad` handler (`MainWindowController.swift`). Both must end the loading state,
// and a build that ends with no index must say so in words instead of leaving a silent empty table.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
import LungfishTestSupport

@MainActor
final class AnnotationDrawerIndexHandoffTests: XCTestCase {
    /// The wait for a drawer to leave its loading state. The build is a file-system read, so it gets 30 seconds
    /// and ends the moment the condition holds.
    private static let drawerBudget = WaitBudget.standard.raised(to: .seconds(30))

    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "drawer-index-handoff")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    // MARK: - ARCH's test: a drawer opened before the bundle-display index ends fills when the build ends

    /// The drawer is opened while no index has reached it, which is the state a drawer is in during a build, and
    /// the bundle-display route then builds its own index. When that build ends the drawer must have left its
    /// loading state and hold the bundle's annotation count.
    ///
    /// `AnnotationSearchIndex.isBuilding` is never true at the base, since `buildIndex` runs to its end on the
    /// main actor, so the case waits on the observable state instead of on that flag.
    func testADrawerOpenedWhileTheBundleDisplayIndexBuildsFillsWhenTheBuildEnds() async throws {
        let bundle = try makeBundle(named: "Handoff Fixture", annotationRows: 3, writesAnnotationDatabase: true)
        let viewer = try showBundle(at: bundle)

        viewer.openAnnotationDrawerIfBundleHasData()
        let drawer = try XCTUnwrap(viewer.annotationDrawerView, "Opening the drawer of a bundle with annotations makes it.")
        XCTAssertTrue(drawer.isLoading, "A drawer that no index has reached shows its loading state.")

        try viewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundle)
        let index = try XCTUnwrap(viewer.annotationSearchIndex, "The bundle-display route keeps the index it builds.")

        let settled = await waitUntil(budget: Self.drawerBudget) { !index.isBuilding && !drawer.isLoading }
        XCTAssertTrue(settled, "The drawer stayed in its loading state after the index build ended.")
        XCTAssertFalse(drawer.isLoading)
        XCTAssertEqual(drawer.totalAnnotationCount, 3, "The drawer holds the bundle's annotation count.")
        XCTAssertTrue(drawer.searchIndex === index, "The drawer holds the index the route built.")

        viewer.clearBundleDisplay()
    }

    // MARK: - UX's test: a build that ends with no index says so

    /// A manifest that names an annotation track whose database file is not there. Each route that builds the
    /// index ends the build with nothing to show, and the drawer must leave its loading state and say why, with
    /// the bundle's name and no Retry button.
    func testAnIndexBuildThatEndsWithNoIndexSaysSo() async throws {
        let bundleName = "Missing Table Fixture"
        let words = "The annotation table could not be built for \(bundleName), because its annotation database "
            + "is missing or cannot be read. Reopen the bundle, and if this repeats, import its annotations again."

        // The bundle-display route.
        let displayBundleURL = try makeBundle(named: bundleName, annotationRows: 0, writesAnnotationDatabase: false)
        let displayViewer = try showBundle(at: displayBundleURL)
        displayViewer.openAnnotationDrawerIfBundleHasData()
        let displayDrawer = try XCTUnwrap(displayViewer.annotationDrawerView)
        try displayViewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: displayBundleURL)
        await assertDrawerSays(words, drawer: displayDrawer, route: "bundle-display route")
        displayViewer.clearBundleDisplay()

        // The window controller's bundleDidLoad route.
        let notifiedBundleURL = try makeBundle(
            named: bundleName, annotationRows: 0, writesAnnotationDatabase: false, folder: "notified"
        )
        let windowController = MainWindowController()
        _ = windowController.window
        let notifiedViewer = try showBundle(at: notifiedBundleURL)
        notifiedViewer.openAnnotationDrawerIfBundleHasData()
        let notifiedDrawer = try XCTUnwrap(notifiedViewer.annotationDrawerView)
        let manifest = try BundleManifest.load(from: notifiedBundleURL)
        let reference = try XCTUnwrap(notifiedViewer.viewerView.currentReferenceBundle)
        NotificationCenter.default.post(
            name: .bundleDidLoad,
            object: notifiedViewer,
            userInfo: [
                NotificationUserInfoKey.bundleURL: notifiedBundleURL,
                NotificationUserInfoKey.chromosomes: manifest.genome?.chromosomes ?? [],
                NotificationUserInfoKey.manifest: manifest,
                NotificationUserInfoKey.referenceBundle: reference,
                NotificationUserInfoKey.windowStateScope: windowController.windowStateScope,
            ]
        )
        await assertDrawerSays(words, drawer: notifiedDrawer, route: "bundleDidLoad route")
        notifiedViewer.clearBundleDisplay()
    }

    // MARK: - Assertions

    private func assertDrawerSays(
        _ words: String, drawer: AnnotationTableDrawerView, route: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let left = await waitUntil(budget: Self.drawerBudget) { !drawer.isLoading }
        XCTAssertTrue(left, "The \(route) left the drawer in its loading state.", file: file, line: line)
        let readable = Self.readableText(in: drawer)
        XCTAssertTrue(
            readable.contains(where: { $0.contains(words) }),
            "The \(route) shows no words for a build that ended with no index. The drawer reads \(readable).",
            file: file, line: line
        )
        XCTAssertFalse(
            readable.contains(where: { $0.localizedCaseInsensitiveContains("Retry") }),
            "The words offer no Retry button.", file: file, line: line
        )
    }

    /// Every string a person can read in the drawer, from its visible labels, fields and button titles.
    private static func readableText(in root: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let field = view as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { found.append(button.title) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: - Fixture

    /// Shows the bundle through the bundle-display route the way the reference-bundle tests do. No window
    /// controller is involved, so no index exists until a route builds one.
    private func showBundle(at bundle: URL) throws -> ViewerViewController {
        let viewer = ViewerViewController()
        _ = viewer.view
        try viewer.displayBundle(at: bundle, mode: .sequence(name: "chr1", restoreViewState: false))
        return viewer
    }

    /// A one-chromosome bundle with a `genes` annotation track. `annotationRows` BED rows go into the database
    /// when `writesAnnotationDatabase` is true, and when it is false the manifest still names the database file
    /// and the file is not there.
    private func makeBundle(
        named name: String, annotationRows: Int, writesAnnotationDatabase: Bool, folder: String = "bundles"
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundle = scratch
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(name).lungfishref", isDirectory: true)
        for member in ["genome", "annotations"] {
            try fileManager.createDirectory(
                at: bundle.appendingPathComponent(member, isDirectory: true), withIntermediateDirectories: true
            )
        }
        let bases = String(repeating: "ACGTTGCAAC", count: 300)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)

        if writesAnnotationDatabase {
            let bed = scratch.appendingPathComponent("genes-\(UUID().uuidString).bed")
            let rows = (0..<annotationRows).map { "chr1\t\(1_000 + $0 * 300)\t\(1_200 + $0 * 300)\tgene-\($0)\t0\t+\n" }
            try rows.joined().write(to: bed, atomically: true, encoding: .utf8)
            _ = try AnnotationDatabase.createFromBED(
                bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db")
            )
            try fileManager.removeItem(at: bed)
        }

        try BundleManifest(
            name: name,
            identifier: "org.lungfish.test.drawer-index-handoff.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: [AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"
            )],
            variants: [],
            tracks: [],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }
}
