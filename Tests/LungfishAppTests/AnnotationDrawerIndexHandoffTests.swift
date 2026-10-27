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
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class AnnotationDrawerIndexHandoffTests: XCTestCase {
    /// The wait for a drawer to leave its loading state. The build is a file-system read, so it gets 30 seconds
    /// and ends the moment the condition holds.
    private static let drawerBudget = WaitBudget.standard.raised(to: .seconds(30))

    /// The first words of the sentence a drawer shows when a build ends with no index.
    private static let failureWordsStart = "The annotation table could not be built for"

    /// The words a drawer shows only while an index is being built (WF-6, the walk of 2026-10-26).
    private static let buildingWords = "Building annotation index"

    /// The words of a drawer that no index will reach, in place of the building words.
    private static let noIndexWords = "No annotations to show for this view."

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
        XCTAssertFalse(
            Self.readableText(in: drawer).contains(where: { $0.contains(Self.failureWordsStart) }),
            "A build that found its table shows no failure words."
        )

        viewer.clearBundleDisplay()
    }

    // MARK: - UX's test: a build that ends with no index says so

    /// A manifest that names an annotation track whose database file is not there. Each route that builds the
    /// index ends the build with nothing to show, and the drawer must leave its loading state and say why, with
    /// the bundle's name and no Retry button.
    func testAnIndexBuildThatEndsWithNoIndexSaysSo() async throws {
        let bundleName = "Missing Table Fixture"
        let words = "\(Self.failureWordsStart) \(bundleName), because its annotation database "
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

    /// The words belong to the build that ended with no index. When the bundle is repaired and the route builds
    /// again, the drawer shows its annotations and the words are gone.
    func testAHealthyBuildTakesTheWordsOfAnEarlierFailedBuildAway() async throws {
        let bundle = try makeBundle(named: "Repaired Fixture", annotationRows: 0, writesAnnotationDatabase: false)
        let viewer = try showBundle(at: bundle)
        viewer.openAnnotationDrawerIfBundleHasData()
        let drawer = try XCTUnwrap(viewer.annotationDrawerView)

        try viewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundle)
        XCTAssertTrue(
            Self.readableText(in: drawer).contains(where: { $0.contains(Self.failureWordsStart) }),
            "Precondition: the failed build shows its words."
        )

        try writeAnnotationDatabase(rows: 2, into: bundle)
        try viewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundle)
        let index = try XCTUnwrap(viewer.annotationSearchIndex)
        let settled = await waitUntil(budget: Self.drawerBudget) { !index.isBuilding && !drawer.isLoading }
        XCTAssertTrue(settled, "The drawer stayed in its loading state after the repaired build ended.")
        XCTAssertEqual(drawer.totalAnnotationCount, 2, "The drawer holds the repaired bundle's annotations.")
        XCTAssertFalse(
            Self.readableText(in: drawer).contains(where: { $0.contains(Self.failureWordsStart) }),
            "The words of the earlier failed build are gone."
        )

        viewer.clearBundleDisplay()
    }

    /// The mapping viewport builds its own index and assigns it straight to the viewer, with no notification and no
    /// helper call (`ReferenceBundleViewportController.swift`). Its drawer exists before that index does, so the
    /// viewer's own observer must give the drawer the words for a build that ends with no index, and take them away
    /// when a later index is healthy (the review of lane DRAWER, blocker 1).
    func testAnIndexAssignedStraightToTheViewerShowsAndTakesAwayTheWords() async throws {
        let bundleName = "Direct Missing Fixture"
        let words = "\(Self.failureWordsStart) \(bundleName), because its annotation database "
            + "is missing or cannot be read. Reopen the bundle, and if this repeats, import its annotations again."
        let bundle = try makeBundle(named: bundleName, annotationRows: 0, writesAnnotationDatabase: false)
        let viewer = try showBundle(at: bundle)
        viewer.openAnnotationDrawerIfBundleHasData()
        let drawer = try XCTUnwrap(viewer.annotationDrawerView)
        let reference = try XCTUnwrap(viewer.viewerView.currentReferenceBundle)

        let failed = AnnotationSearchIndex()
        failed.buildIndex(bundle: reference, chromosomes: [])
        viewer.annotationSearchIndex = failed
        await assertDrawerSays(words, drawer: drawer, route: "direct assignment")

        try writeAnnotationDatabase(rows: 2, into: bundle)
        let repaired = AnnotationSearchIndex()
        repaired.buildIndex(bundle: reference, chromosomes: [])
        viewer.annotationSearchIndex = repaired
        let filled = await waitUntil(budget: Self.drawerBudget) { drawer.totalAnnotationCount == 2 }
        XCTAssertTrue(filled, "The drawer holds the repaired bundle's annotations.")
        XCTAssertFalse(
            Self.readableText(in: drawer).contains(where: { $0.contains(Self.failureWordsStart) }),
            "The words of the earlier failed build are gone."
        )

        viewer.clearBundleDisplay()
    }

    // MARK: - WF-6, DRAWER-ROUTE: View > Show Drawer reaches the drawer the person sees

    /// The walk's order of events. A reference bundle opens in the host's viewport, whose embedded viewer opens its
    /// drawer and fills it. View > Show Drawer goes to the host, which must act on that drawer and must make no
    /// drawer of its own over the viewport. At the base the host made a second, empty drawer whose count label read
    /// "Building annotation index (scanning all chromosomes)..." for good.
    func testShowDrawerThroughTheHostOnAReferenceViewportTogglesTheEmbeddedDrawer() throws {
        let bundle = try makeBundle(named: "Viewport Fixture", annotationRows: 3, writesAnnotationDatabase: true)
        let host = makeHost()
        let viewport = try showViewport(
            .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)), in: host
        )
        let embedded = viewport.testEmbeddedViewerController
        let embeddedDrawer = try XCTUnwrap(embedded.annotationDrawerView, "The embedded viewer makes its drawer.")
        XCTAssertTrue(embedded.isAnnotationDrawerOpen, "The embedded viewer opens its drawer for a bundle with annotations.")
        XCTAssertFalse(embeddedDrawer.isLoading, "The embedded drawer has its index.")
        XCTAssertEqual(embeddedDrawer.totalAnnotationCount, 3, "The embedded drawer lists the bundle's annotations.")

        // View > Show Drawer: the window controller sends the toggle to the host viewer.
        host.toggleAnnotationDrawer()
        XCTAssertNil(host.annotationDrawerView, "Show Drawer made a second drawer in the host, over the viewport.")
        XCTAssertFalse(host.isActiveDrawerOpen, "The first toggle hides the drawer that lists the annotations.")
        XCTAssertFalse(embedded.isAnnotationDrawerOpen, "The first toggle left the embedded drawer open.")
        XCTAssertFalse(
            Self.readableText(in: host.view).contains(where: { $0.contains(Self.buildingWords) }),
            "A drawer reads the building words while no index is building."
        )

        host.toggleAnnotationDrawer()
        XCTAssertNil(host.annotationDrawerView, "The second toggle made a drawer in the host.")
        XCTAssertTrue(host.isActiveDrawerOpen, "The second toggle shows the drawer again.")
        XCTAssertTrue(embedded.isAnnotationDrawerOpen, "The second toggle left the embedded drawer closed.")
        XCTAssertFalse(embeddedDrawer.isLoading)
        XCTAssertEqual(embeddedDrawer.totalAnnotationCount, 3, "The drawer holds its annotations after Hide and Show.")
        let words = Self.readableText(in: host.view)
        XCTAssertFalse(
            words.contains(where: { $0.contains(Self.buildingWords) }),
            "A drawer reads the building words while no index is building. The view tree reads \(words)."
        )
        XCTAssertTrue(words.contains("3 annotations"), "The drawer reads its count. The view tree reads \(words).")
    }

    /// A mapping result's reference with no annotation or variant track opens no drawer of its own. Show Drawer
    /// makes the embedded viewer's drawer, which holds an index with no rows and reads "0 annotations", never the
    /// building words over an empty table.
    func testShowDrawerOnAMappingViewportWithNoAnnotationsReadsZero() async throws {
        let bundle = try makeBundle(
            named: "Mapping Fixture", annotationRows: 0, writesAnnotationDatabase: false, includesAnnotationTrack: false
        )
        let host = makeHost()
        let viewport = try showViewport(try makeMappingInput(viewerBundle: bundle), in: host)
        let loaded = await waitUntil(budget: Self.drawerBudget) { viewport.loadedViewerBundleURL != nil }
        XCTAssertTrue(loaded, "The mapping viewport loads its reference bundle into the embedded viewer.")
        let embedded = viewport.testEmbeddedViewerController
        XCTAssertNil(embedded.annotationDrawerView, "A reference with no annotation or variant track opens no drawer.")

        host.toggleAnnotationDrawer()
        XCTAssertNil(host.annotationDrawerView, "Show Drawer made an empty drawer in the host, over the viewport.")
        let drawer = try XCTUnwrap(embedded.annotationDrawerView, "Show Drawer made no drawer in the embedded viewer.")
        XCTAssertTrue(host.isActiveDrawerOpen, "The menu and the toolbar button read the drawer the person sees.")
        XCTAssertFalse(drawer.isLoading, "No index is building, so the drawer is not loading.")
        let words = Self.readableText(in: host.view)
        XCTAssertTrue(words.contains("0 annotations"), "The drawer reads its count. The view tree reads \(words).")
        XCTAssertFalse(
            words.contains(where: { $0.contains(Self.buildingWords) }),
            "A drawer reads the building words while no index is building. The view tree reads \(words)."
        )
    }

    /// A drawer made while no index exists, and none is building, says so in words. The bundle-display route in a
    /// viewer with no window controller builds no index, and its build is never waiting on a later turn, so the
    /// drawer must not read the building words for good.
    func testADrawerMadeWithNoIndexShowsTheNoIndexWords() throws {
        let bundle = try makeBundle(named: "No Index Fixture", annotationRows: 3, writesAnnotationDatabase: true)
        let viewer = try showBundle(at: bundle)
        XCTAssertNil(viewer.annotationSearchIndex, "Precondition: no route built an index.")
        let drawer = try XCTUnwrap(viewer.annotationDrawerView, "Opening a bundle with annotations makes its drawer.")

        XCTAssertFalse(drawer.isLoading, "No index is building, so the drawer is not loading.")
        let words = Self.readableText(in: drawer)
        XCTAssertFalse(
            words.contains(where: { $0.contains(Self.buildingWords) }),
            "A drawer reads the building words while no index is building. The drawer reads \(words)."
        )
        XCTAssertTrue(
            words.contains(where: { $0.contains(Self.noIndexWords) }),
            "A drawer that no index will reach says so. The drawer reads \(words)."
        )

        viewer.clearBundleDisplay()
    }

    /// Make Drawer Taller and the project-change close act on the drawer the person sees, never on a drawer the host
    /// makes over the viewport.
    func testMakeDrawerTallerAndCloseDrawerActOnTheEmbeddedDrawer() throws {
        let bundle = try makeBundle(named: "Resize Fixture", annotationRows: 3, writesAnnotationDatabase: true)
        let host = makeHost()
        let viewport = try showViewport(
            .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)), in: host
        )
        let embedded = viewport.testEmbeddedViewerController
        XCTAssertTrue(embedded.isAnnotationDrawerOpen, "Precondition: the embedded drawer is open.")

        host.adjustAnnotationDrawerHeight(by: 40)
        XCTAssertNil(host.annotationDrawerView, "Make Drawer Taller made a drawer in the host, over the viewport.")
        XCTAssertTrue(embedded.isAnnotationDrawerOpen, "Make Drawer Taller closed the embedded drawer.")

        host.closeAnnotationDrawer()
        XCTAssertFalse(embedded.isAnnotationDrawerOpen, "Closing the drawer left the embedded drawer open.")
        XCTAssertNil(host.annotationDrawerView, "Closing the drawer made a drawer in the host.")
    }

    /// The menu item and the toolbar button read the open state of the drawer the person sees, so Hide Drawer and
    /// Show Drawer follow the embedded drawer through the window controller's own validation.
    func testDrawerMenuTitleFollowsTheEmbeddedDrawer() throws {
        let bundle = try makeBundle(named: "Menu Fixture", annotationRows: 3, writesAnnotationDatabase: true)
        let windowController = MainWindowController()
        _ = windowController.window
        let host = try XCTUnwrap(windowController.mainSplitViewController.viewerController)
        _ = host.view
        let viewport = try showViewport(
            .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)), in: host
        )
        let embedded = viewport.testEmbeddedViewerController
        let item = NSMenuItem(
            title: "Show Drawer", action: #selector(MainWindowController.toggleAnnotationDrawer(_:)), keyEquivalent: ""
        )

        XCTAssertTrue(windowController.validateMenuItem(item))
        XCTAssertEqual(item.title, "Hide Drawer", "The drawer that lists the annotations is open, so the menu offers Hide.")
        windowController.toggleAnnotationDrawer(nil)
        XCTAssertTrue(windowController.validateMenuItem(item))
        XCTAssertEqual(item.title, "Show Drawer", "The drawer is hidden, so the menu offers Show.")
        XCTAssertFalse(embedded.isAnnotationDrawerOpen)
        windowController.toggleAnnotationDrawer(nil)
        XCTAssertTrue(windowController.validateMenuItem(item))
        XCTAssertEqual(item.title, "Hide Drawer", "The drawer is shown again, so the menu offers Hide.")
        XCTAssertTrue(embedded.isAnnotationDrawerOpen)
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

        // The words are laid out where a person reads them, inside the drawer and wrapped to a readable width.
        drawer.superview?.layoutSubtreeIfNeeded()
        guard let notice = drawer.subviews.first(where: { $0.identifier == AnnotationDrawerIndexHandoff.noticeIdentifier }) else {
            return XCTFail("The words sit in no view of the drawer.", file: file, line: line)
        }
        XCTAssertGreaterThan(notice.frame.height, 0, "The words have a height.", file: file, line: line)
        XCTAssertLessThanOrEqual(notice.frame.width, 520.5, "The words wrap at a readable width.", file: file, line: line)
        XCTAssertTrue(drawer.bounds.contains(notice.frame), "The words lie inside the drawer.", file: file, line: line)
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

    /// Shows the bundle through the bundle-display route the way the reference-bundle tests do, in a viewer of a
    /// real size. No window controller is involved, so no index exists until a route builds one.
    private func showBundle(at bundle: URL) throws -> ViewerViewController {
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        try viewer.displayBundle(at: bundle, mode: .sequence(name: "chr1", restoreViewState: false))
        viewer.view.layoutSubtreeIfNeeded()
        return viewer
    }

    /// The host viewer a window shows, in a viewer of a real size and with no display installed.
    private func makeHost() -> ViewerViewController {
        let host = ViewerViewController()
        _ = host.view
        host.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        return host
    }

    /// Installs the reference viewport on the host the way the sidebar route does and returns it.
    private func showViewport(
        _ input: ReferenceBundleViewportInput, in host: ViewerViewController
    ) throws -> ReferenceBundleViewportController {
        try host.displayReferenceBundleViewport(input)
        host.view.layoutSubtreeIfNeeded()
        return try XCTUnwrap(host.referenceBundleViewportController, "The host installs the reference viewport.")
    }

    /// A mapping result whose viewer bundle is `viewerBundle`, with one contig named after the bundle's chromosome
    /// so that the viewport selects it and loads the bundle into its embedded viewer.
    private func makeMappingInput(viewerBundle: URL) throws -> ReferenceBundleViewportInput {
        let resultDirectory = scratch.appendingPathComponent("mapping-run", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let bam = resultDirectory.appendingPathComponent("sample.sorted.bam")
        let bai = resultDirectory.appendingPathComponent("sample.sorted.bam.bai")
        try Data("bam".utf8).write(to: bam)
        try Data("bai".utf8).write(to: bai)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundle,
            bamURL: bam,
            baiURL: bai,
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: [MappingContigSummary(
                contigName: "chr1", contigLength: 3_000, mappedReads: 9, mappedReadPercent: 90, meanDepth: 1,
                coverageBreadth: 50, medianMAPQ: 60, meanIdentity: 99
            )]
        )
        return .mappingResult(result: result, resultDirectoryURL: resultDirectory, provenance: nil)
    }

    /// A one-chromosome bundle with a `genes` annotation track. `annotationRows` BED rows go into the database
    /// when `writesAnnotationDatabase` is true, and when it is false the manifest still names the database file
    /// and the file is not there. With `includesAnnotationTrack` false the manifest names no track at all.
    private func makeBundle(
        named name: String, annotationRows: Int, writesAnnotationDatabase: Bool, folder: String = "bundles",
        includesAnnotationTrack: Bool = true
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
        if writesAnnotationDatabase { try writeAnnotationDatabase(rows: annotationRows, into: bundle) }

        try BundleManifest(
            name: name,
            identifier: "org.lungfish.test.drawer-index-handoff.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: includesAnnotationTrack ? [AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"
            )] : [],
            variants: [],
            tracks: [],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    /// Writes `annotations/genes.db` into the bundle from `rows` BED rows, the file its manifest names.
    private func writeAnnotationDatabase(rows: Int, into bundle: URL) throws {
        let bed = scratch.appendingPathComponent("genes-\(UUID().uuidString).bed")
        let records = (0..<rows).map { "chr1\t\(1_000 + $0 * 300)\t\(1_200 + $0 * 300)\tgene-\($0)\t0\t+\n" }
        try records.joined().write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(
            bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db")
        )
        try FileManager.default.removeItem(at: bed)
    }
}
