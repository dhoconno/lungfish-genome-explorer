// ViewerGraphicsExportRouteReachTests.swift - File > Export > Image of a bundle the sidebar opened
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane OBS11 (obs-11, walk row 80), ARCH's ruling and the UX, BIO and QA riders. The sidebar opens a
// `.lungfishref` and a mapping result in the reference viewport. The viewport draws the bundle in its embedded viewer
// and leaves the viewer the menu passes in `.mapping` with its sequence view hidden and no `currentBundleURL`. Each
// test opens one kind through the sidebar's own open call in a main window, then reads what File > Export > Image
// reads from the viewer `exportImage(_:)` takes. The pane resolves to the bundle the viewport draws, the Scope list is
// that bundle's list with the selection of the viewer that draws, and Save begins an Export Image row whose command is
// `lungfish-cli bundle export-graphic` on that bundle over the window that viewer shows.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViewerGraphicsExportRouteReachTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerGraphicsExportRouteReach")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    // MARK: - The three kinds

    /// A `.lungfishref` with a gene track, opened by the sidebar's reference route. BIO: the image shows its sequence
    /// and its annotations.
    func testReferenceBundleOpenedFromSidebarExportsThroughBundleExportGraphic() async throws {
        let bundle = try makeBundle(named: "Annotated", in: folder, annotated: true)
        let (delegate, controller, split) = try makeWindow()
        defer { controller.close() }
        split.displayReferenceBundleViewportFromSidebar(at: bundle)
        let drawing = try await waitForDrawnBundle(in: split.viewerController) { $0.referenceBundleViewportController }
        try await assertExportReachesTheLeaf(
            delegate: delegate, drawing: drawing, drawn: bundle, drawsReads: false, kind: "lungfishref"
        )
    }

    /// A mapping result opened by the sidebar's mapping route, whose viewer bundle is the mapping's own copy of its
    /// reference with the read track (Q-A24). BIO: the image shows the reads against that reference. The same result
    /// shown by `displayMappingResult`, the viewer's other mapping route, draws through `mappingResultController`.
    func testMappingResultOpenedFromSidebarExportsThroughBundleExportGraphic() async throws {
        let mapping = try makeMappingResult()
        let (delegate, controller, split) = try makeWindow()
        defer { controller.close() }
        split.displayMappingAnalysisFromSidebar(at: mapping.folder)
        let drawing = try await waitForDrawnBundle(in: split.viewerController) { $0.referenceBundleViewportController }
        try await assertExportReachesTheLeaf(
            delegate: delegate, drawing: drawing, drawn: mapping.viewerBundle, drawsReads: true, kind: "mapping-result"
        )

        split.viewerController.displayMappingResult(mapping.result, resultDirectoryURL: mapping.folder)
        let shown = try await waitForDrawnBundle(in: split.viewerController) { $0.mappingResultController }
        try await assertExportReachesTheLeaf(
            delegate: delegate, drawing: shown, drawn: mapping.viewerBundle, drawsReads: true, kind: "mapping-result-view"
        )
    }

    /// A `.lungfishref` with a sequence and no track, opened by the sidebar's reference route. BIO: the image shows
    /// its sequence and the ruler only.
    func testBundleWithNoTracksExportsThroughBundleExportGraphic() async throws {
        let bundle = try makeBundle(named: "Bare", in: folder, annotated: false)
        let (delegate, controller, split) = try makeWindow()
        defer { controller.close() }
        split.displayReferenceBundleViewportFromSidebar(at: bundle)
        let drawing = try await waitForDrawnBundle(in: split.viewerController) { $0.referenceBundleViewportController }
        try await assertExportReachesTheLeaf(
            delegate: delegate, drawing: drawing, drawn: bundle, drawsReads: false, kind: "no-tracks"
        )
    }

    // MARK: - What File > Export > Image reads

    /// Reads the viewer the menu passes, as `exportImage(_:)` finds it, and asserts the three things of the brief.
    /// `drawing` is the viewport's embedded viewer, through its test seam, and `drawn` is the bundle it draws.
    private func assertExportReachesTheLeaf(
        delegate: AppDelegate,
        drawing: ViewerViewController,
        drawn: URL,
        drawsReads: Bool,
        kind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let viewer = try XCTUnwrap(delegate.mainWindowController?.mainSplitViewController?.viewerController)
        let state = paneState(of: viewer)
        print("Pane state, \(kind): \(state)")

        // 1. The pane resolves to the bundle the viewport draws.
        let listed = AppDelegate.viewerGraphicsExportScopes(viewerController: viewer)
        guard case .referenceBundle(let listedURL) = listed.content else {
            return XCTFail("\(kind) resolves to \(listed.content), not its bundle. Pane: \(state)", file: file, line: line)
        }
        XCTAssertEqual(listedURL.standardizedFileURL.path, drawn.standardizedFileURL.path, kind, file: file, line: line)

        // 2. The Scope list is the bundle's, with the selection of the viewer that draws (UX rider).
        XCTAssertEqual(listed.scopes.map(\.title), ["Tracks", "Ruler and Tracks"], kind, file: file, line: line)
        drawing.viewerView.selectionRange = 10..<40
        drawing.viewerView.isUserColumnSelection = true
        XCTAssertEqual(
            AppDelegate.viewerGraphicsExportScopes(viewerController: viewer).scopes.map(\.title),
            ["Tracks", "Ruler and Tracks", "Selected Region"],
            "\(kind): the user's selection in the viewer that draws", file: file, line: line
        )
        drawing.viewerView.selectionRange = nil

        // 3. Save begins an Export Image row that runs `bundle export-graphic` (QA rider).
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(delegate.finishViewerGraphicsExport(
            viewerController: viewer, content: listed.content, scope: .tracks, format: .png, bitmapScale: 2,
            outputURL: folder.appendingPathComponent("\(kind).png"),
            presentAlert: { _ in }, // /usr/bin/true reports no completion, so the row fails after it began
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ), "\(kind): Save began no row. Pane: \(state)", file: file, line: line)
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first, file: file, line: line)
        XCTAssertEqual(item.id, begun.operationID, file: file, line: line)
        XCTAssertEqual(item.title, "Export Image", file: file, line: line)
        XCTAssertEqual(item.operationType, .export, file: file, line: line)
        let words = try AdvancedCommandLineOptions.parse(try XCTUnwrap(item.cliCommand, file: file, line: line))
        XCTAssertEqual(Array(words.prefix(3)), ["lungfish-cli", "bundle", "export-graphic"], kind, file: file, line: line)
        XCTAssertEqual(
            words.count > 3 ? URL(fileURLWithPath: words[3]).standardizedFileURL.path : nil,
            drawn.standardizedFileURL.path, "\(kind): the leaf draws the bundle the pane draws", file: file, line: line
        )
        let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(Array(words.dropFirst())))
        let command = try XCTUnwrap(parsed as? BundleExportGraphicSubcommand, kind, file: file, line: line)
        let frame = try XCTUnwrap(drawing.referenceFrame, file: file, line: line)
        XCTAssertEqual(
            command.graphic.region,
            AppDelegate.viewerGraphicsExportRegion(
                contig: frame.chromosome, start: frame.start, end: frame.end, length: frame.sequenceLength
            ),
            "\(kind): the window of the viewer that draws", file: file, line: line
        )
        XCTAssertEqual(
            command.graphic.settings.excludeFlags != nil, drawsReads,
            "\(kind): the read filters pass only for a bundle with reads", file: file, line: line
        )
    }

    /// The pane state the export read at the base, and the viewer that draws, for the lane report's table.
    private func paneState(of viewer: ViewerViewController) -> String {
        func shown(_ viewer: ViewerViewController) -> String { viewer.viewerView.isHidden ? "hidden" : "shown" }
        func name(_ url: URL?) -> String { url?.lastPathComponent ?? "nil" }
        let viewport: ReferenceBundleViewportController? = viewer.referenceBundleViewportController
            ?? viewer.mappingResultController
        var viewportText = "nil"
        if let viewport {
            let input = viewport.currentInput.map { "\($0.kind)" } ?? "no input"
            viewportText = "\(type(of: viewport)) \(input) \(name(viewport.currentInput?.renderedBundleURL))"
        }
        var embeddedText = "nil"
        if let embedded = viewport?.testEmbeddedViewerController {
            embeddedText = "\(embedded.contentMode) \(shown(embedded)) \(name(embedded.currentBundleURL))"
        }
        let children = viewer.children.map { "\(type(of: $0))" }.joined(separator: ",")
        return "contentMode=\(viewer.contentMode) viewerView=\(shown(viewer)) currentBundleURL=\(name(viewer.currentBundleURL))"
            + " viewport=\(viewportText) children=[\(children)] embedded=\(embeddedText)"
    }

    // MARK: - Fixtures

    /// A main window and its split, as the app makes them, with the delegate's window state in the test folder.
    private func makeWindow() throws -> (AppDelegate, MainWindowController, MainSplitViewController) {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.projectWindowStateStore = ProjectWindowStateStore(stateURL: folder.appendingPathComponent("windows.json"))
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        return (delegate, controller, try XCTUnwrap(controller.mainSplitViewController))
    }

    /// Waits up to 30 seconds for the viewport `viewport` returns to draw its bundle, and returns its embedded viewer.
    private func waitForDrawnBundle(
        in viewer: ViewerViewController,
        through viewport: (ViewerViewController) -> ReferenceBundleViewportController?
    ) async throws -> ViewerViewController {
        let drew = await waitUntil(timeout: .seconds(30)) {
            viewport(viewer)?.testEmbeddedViewerController.referenceFrame != nil
        }
        XCTAssertTrue(drew, "the viewport never drew its bundle. Pane: \(paneState(of: viewer))")
        return try XCTUnwrap(viewport(viewer)?.testEmbeddedViewerController)
    }

    /// A bundle with `chr1` of 1,000 bases, a gene track when `annotated` and a read track when `reads`.
    private func makeBundle(named name: String, in directory: URL, annotated: Bool, reads: Bool = false) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try ">chr1\n\(String(repeating: "ACGTTGCA", count: 125))\n"
            .write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t1000\t6\t1000\t1001\n"
            .write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        var annotations: [AnnotationTrackInfo] = []
        if annotated {
            let tracks = bundle.appendingPathComponent("annotations", isDirectory: true)
            try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
            let bed = directory.appendingPathComponent("\(name).bed")
            try "chr1\t100\t400\tORF1ab\t0\t+\t100\t400\t0,0,0\t1\t300\t0\tgene\tgene=ORF1ab\n"
                .write(to: bed, atomically: true, encoding: .utf8)
            try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: tracks.appendingPathComponent("genes.db"))
            annotations = [AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.db", databasePath: "annotations/genes.db",
                annotationType: .gene, featureCount: 1, source: "Test"
            )]
        }
        var alignments: [AlignmentTrackInfo] = []
        if reads {
            let tracks = bundle.appendingPathComponent("alignments", isDirectory: true)
            try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
            try Data().write(to: tracks.appendingPathComponent("reads.bam"))
            try Data().write(to: tracks.appendingPathComponent("reads.bam.bai"))
            let database = try AlignmentMetadataDatabase.create(at: tracks.appendingPathComponent("reads.metadata.sqlite"))
            database.addChromosomeStats(chromosome: "chr1", length: 1000, mapped: 1, unmapped: 0)
            alignments = [AlignmentTrackInfo(
                id: "reads", name: "Reads", sourcePath: "alignments/reads.bam", indexPath: "alignments/reads.bam.bai",
                metadataDBPath: "alignments/reads.metadata.sqlite", mappedReadCount: 1, unmappedReadCount: 0,
                sampleNames: ["S1"]
            )]
        }
        try BundleManifest(
            formatVersion: "1.0",
            name: name,
            identifier: "org.lungfish.route-reach.\(name.lowercased())",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 1000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 1000, offset: 6, lineBases: 1000, lineWidth: 1001)]
            ),
            annotations: annotations,
            alignments: alignments
        ).save(to: bundle)
        return bundle
    }

    /// A mapping result folder with its viewer bundle inside it, named for its reference, as
    /// `MappingResultLayoutService` lays it out, holding the mapping's read track.
    private func makeMappingResult() throws -> (result: MappingResult, folder: URL, viewerBundle: URL) {
        let resultURL = folder.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        let viewerBundle = try makeBundle(named: "Mapped", in: resultURL, annotated: false, reads: true)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundle,
            bamURL: viewerBundle.appendingPathComponent("alignments/reads.bam"),
            baiURL: viewerBundle.appendingPathComponent("alignments/reads.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        try result.save(to: resultURL)
        return (result, resultURL, viewerBundle)
    }
}
