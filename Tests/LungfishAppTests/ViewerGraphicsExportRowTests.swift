// ViewerGraphicsExportRowTests.swift - The Operations row, scopes and alerts of the viewer image export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2), UX ruling Q-G2 items 1 to 6, BIO ruling Q-G3 items 2 and 3, QA conditions 1 and 2
// of the V1 vote. `AppDelegate.beginViewerGraphicsExportOperation` begins an export row with no lock and a cancel
// callback and records the `bundle export-graphic` command the runner runs (rule 5 of `cli-parity-gaps`). A bundle in
// the sequence viewer runs the leaf for Tracks, Ruler and Tracks and Selected Region. A document keeps its Tracks,
// Full Viewer Pane and Selected Region captures and any other view its Full Viewer Pane capture, which begin no row.
// The kinds the test can show for real are shown through the viewer's own display calls. The others are given as the
// pane state their display call sets, with the line that sets it.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishWorkflow

@MainActor
final class ViewerGraphicsExportAlertLog {
    var alerts: [ViewerGraphicsExportAlert] = []
}

@MainActor
final class ViewerGraphicsExportRowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "ViewerGraphicsExportRow")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    private func trueRunner() -> CLIViewerExportRunner {
        CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true"))
    }

    /// A main window and its viewer, as `ViewerPaneCapturePinTests` makes them.
    private func makeViewer() throws -> (AppDelegate, MainWindowController, ViewerViewController) {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        delegate.testingSetMainWindowControllers([controller])
        return (delegate, controller, try XCTUnwrap(controller.mainSplitViewController?.viewerController))
    }

    /// A reference bundle with `chr1` of 3,000 bases in a plain FASTA and no tracks.
    private func makeBundle() throws -> URL {
        let bundle = folder.appendingPathComponent("Row Fixture.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("genome"), withIntermediateDirectories: true)
        let bases = String(repeating: "ACGTTGCA", count: 375)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: "SARS-CoV-2 reference",
            identifier: "org.lungfish.row-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: [],
            variants: [],
            tracks: [],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    private func displayDocument(in viewer: ViewerViewController) throws {
        let document = LoadedDocument(url: URL(fileURLWithPath: "/tmp/invented-export.fa"), type: .fasta)
        document.sequences = [try Sequence(name: "invented", alphabet: .dna, bases: String(repeating: "ACGT", count: 250))]
        viewer.displayDocument(document)
    }

    private func titles(_ viewer: ViewerViewController) -> [String] {
        AppDelegate.viewerGraphicsExportScopes(viewerController: viewer).scopes.map(\.title)
    }

    private func pane(
        bundleURL: URL? = nil, _ mode: ViewportContentMode, shown: Bool, dashboard: Bool = false, document: Bool = false
    ) -> ViewerGraphicsExportContent {
        AppDelegate.viewerGraphicsExportContent(of: ViewerGraphicsExportPaneState(
            bundleURL: bundleURL, contentMode: mode, sequenceViewShown: shown,
            documentDashboardShown: dashboard, hasDocument: document
        ))
    }

    // MARK: - UX item 1, the row

    func testViewerGraphicsExportRowNamesTheFileBundleAndRegion() async throws {
        let bundle = URL(fileURLWithPath: "/tmp/lane 13.30/SARS-CoV-2.lungfishref", isDirectory: true)
        let output = URL(fileURLWithPath: "/tmp/lane 13.30/viewer-export.png")
        let invocation = ViewerGraphicExport.invocation(
            bundleURL: bundle,
            settings: .init(region: "NC_045512.2:1-29903", width: 812, format: .png, scale: 2, theme: .light),
            outputURL: output, force: false
        )
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AppDelegate.beginViewerGraphicsExportOperation(
            invocation: invocation, bundleName: "SARS-CoV-2 reference", runner: trueRunner(), reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Image")
        XCTAssertEqual(item.initialDetail, "Writing viewer-export.png from SARS-CoV-2 reference, NC_045512.2:1-29903")
        let words = AppDelegate.viewerGraphicsExportRowWords(
            arguments: invocation.arguments(), bundleName: "SARS-CoV-2 reference", outputURL: output
        )
        XCTAssertEqual(words.completionDetail, "Exported viewer-export.png")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: BundleExportGraphicSubcommand.self)
        XCTAssertEqual(command.invocation(), invocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.graphic.region, "NC_045512.2:1-29903")
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    // MARK: - UX items 2 and 3, QA condition 2, the scopes of each content kind

    /// Kind 1, a reference bundle in sequence mode. Selected Region needs a selection the user made. At the base the
    /// panel offered it for any non-empty `selectionRange`, which the viewport also sets (the defect fix).
    func testViewerGraphicsExportScopesForAReferenceBundle() async throws {
        let (delegate, controller, viewer) = try makeViewer()
        defer { controller.close() }
        let bundle = try makeBundle()
        try viewer.displayBundle(at: bundle, mode: .sequence(name: "chr1", restoreViewState: false))
        let view = try XCTUnwrap(viewer.viewerView)
        view.selectionRange = nil
        let listed = AppDelegate.viewerGraphicsExportScopes(viewerController: viewer)
        XCTAssertEqual(listed.content, .referenceBundle(bundle))
        XCTAssertEqual(listed.scopes.map(\.title), ["Tracks", "Ruler and Tracks"])
        view.selectionRange = 100..<300
        view.isUserColumnSelection = false
        XCTAssertEqual(titles(viewer), ["Tracks", "Ruler and Tracks"], "a viewport selection offers no Selected Region")
        view.isUserColumnSelection = true
        XCTAssertEqual(titles(viewer), ["Tracks", "Ruler and Tracks", "Selected Region"])

        let frame = try XCTUnwrap(viewer.referenceFrame)
        let window = AppDelegate.viewerGraphicsExportRegion(contig: "chr1", start: frame.start, end: frame.end, length: 3000)
        let selection = AppDelegate.viewerGraphicsExportRegion(
            contig: "chr1", start: max(100, frame.start), end: min(300, frame.end), length: 3000
        )
        let expected: [(ViewerExportScope, String, Bool)] = [
            (.tracks, window, false), (.rulerAndTracks, window, true), (.selectedRegion, selection, false),
        ]
        for (scope, region, ruler) in expected {
            let reporter = RecordingOperationReporter()
            let begun = try XCTUnwrap(delegate.finishViewerGraphicsExport(
                viewerController: viewer, content: listed.content, scope: scope, format: .png, bitmapScale: 2,
                outputURL: folder.appendingPathComponent("\(scope.rawValue).png"),
                presentAlert: { _ in }, // /usr/bin/true reports no completion, so the row fails after it began

                runner: trueRunner(), reporter: reporter
            ))
            _ = await begun.task.value
            let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: BundleExportGraphicSubcommand.self)
            let settings = command.graphic.settings
            XCTAssertEqual(settings.region, region, "\(scope)")
            XCTAssertEqual(settings.includeRuler, ruler, "\(scope)")
            XCTAssertEqual(settings.format, .png)
            XCTAssertEqual(settings.scale, 2)
            XCTAssertNotNil(settings.theme, "the app always passes the theme")
            XCTAssertNotNil(settings.width, "the app always passes the width")
            XCTAssertNil(settings.excludeFlags, "no alignment is drawn")
            XCTAssertNil(settings.coverageScale, "no alignment is drawn")
            let viewState = try XCTUnwrap(settings.viewState)
            XCTAssertNoThrow(try ViewerGraphicViewState.read(from: URL(fileURLWithPath: viewState)), "written before begin")
        }
    }

    /// Kinds 2, 3, 4 and 8. A `.browse` bundle shows the reference viewport, which never sets `currentBundleURL`
    /// (`ViewerViewController+BundleDisplay.swift:54-56`). A mapping result clears the bundle and sets `.mapping`
    /// (`ViewerViewController+Mapping.swift:110-112`). An MSA bundle sets `.genomics` and hides the sequence viewer
    /// (`ViewerViewController+AlignmentTreeBundles.swift:122`, `:198`). A classifier result sets `.metagenomics` and
    /// hides it (`ViewerViewController+Taxonomy.swift:58`, `:266`), even when a bundle URL is left over. Kind 9, the
    /// empty pane, is shown for real, and its capture writes the file and begins no row.
    func testViewerGraphicsExportScopesForOtherContent() throws {
        let stale = URL(fileURLWithPath: "/tmp/stale.lungfishref", isDirectory: true)
        for mode in [ViewportContentMode.genomics, .empty] {
            for shown in [true, false] {
                XCTAssertEqual(pane(mode, shown: shown), .other, "browse bundle, \(mode), shown \(shown)")
            }
        }
        XCTAssertEqual(pane(.mapping, shown: false), .other, "mapping result")
        XCTAssertEqual(pane(.genomics, shown: false), .other, "MSA bundle")
        XCTAssertEqual(pane(bundleURL: stale, .metagenomics, shown: false), .other, "classifier result")
        XCTAssertEqual(pane(bundleURL: stale, .genomics, shown: false), .other, "a hidden sequence viewer")
        XCTAssertEqual(
            AppDelegate.viewerGraphicsExportScopes(for: .other, hasSelection: true, isUserSelection: true).map(\.title),
            ["Full Viewer Pane"]
        )

        let (delegate, controller, viewer) = try makeViewer()
        defer { controller.close() }
        viewer.viewerView.selectionRange = 10..<20
        let listed = AppDelegate.viewerGraphicsExportScopes(viewerController: viewer)
        XCTAssertEqual(listed.content, .other, "the empty pane")
        XCTAssertEqual(listed.scopes.map(\.title), ["Full Viewer Pane"])
        let rowsBefore = OperationCenter.shared.items.count
        let log = ViewerGraphicsExportAlertLog()
        let output = folder.appendingPathComponent("pane.pdf")
        XCTAssertNil(delegate.finishViewerGraphicsExport(
            viewerController: viewer, content: listed.content, scope: .fullViewer, format: .pdf, bitmapScale: 1,
            outputURL: output, presentAlert: { log.alerts.append($0) }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(log.alerts, [.captured(fileName: "pane.pdf")])
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "a capture begins no row")
    }

    /// Kinds 5, 6 and 7. A document from `displayDocument` and a FASTA collection are shown for real. A VCF dataset
    /// hides the sequence viewer under its dashboard (`ViewerViewController.swift:1534-1555`).
    func testViewerGraphicsExportScopesForADocumentThatIsNotABundle() throws {
        let (delegate, controller, viewer) = try makeViewer()
        defer { controller.close() }
        try displayDocument(in: viewer)
        viewer.viewerView.selectionRange = nil
        XCTAssertEqual(AppDelegate.viewerGraphicsExportScopes(viewerController: viewer).content, .document)
        XCTAssertEqual(titles(viewer), ["Tracks", "Full Viewer Pane"])
        viewer.viewerView.selectionRange = 100..<300
        viewer.viewerView.isUserColumnSelection = false
        let listed = AppDelegate.viewerGraphicsExportScopes(viewerController: viewer)
        XCTAssertEqual(listed.scopes.map(\.title), ["Tracks", "Full Viewer Pane", "Selected Region"], "today's rule")

        let rowsBefore = OperationCenter.shared.items.count
        let log = ViewerGraphicsExportAlertLog()
        for scope in listed.scopes {
            let output = folder.appendingPathComponent("\(scope.rawValue).pdf")
            XCTAssertNil(delegate.finishViewerGraphicsExport(
                viewerController: viewer, content: listed.content, scope: scope, format: .pdf, bitmapScale: 1,
                outputURL: output, presentAlert: { log.alerts.append($0) }
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(scope)")
        }
        XCTAssertEqual(log.alerts, listed.scopes.map { .captured(fileName: "\($0.rawValue).pdf") })
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore, "a capture begins no row")

        XCTAssertEqual(pane(.empty, shown: false, dashboard: true), .document, "VCF dataset")
        viewer.displayFASTACollection(sequences: viewer.currentDocument?.sequences ?? [], annotations: [])
        XCTAssertEqual(AppDelegate.viewerGraphicsExportScopes(viewerController: viewer).content, .document, "FASTA collection")
    }

    // MARK: - UX items 4 and 5, the alerts

    func testViewerPaneCaptureKeepsItsAlertWordsAndBeginsNoRow() throws {
        let (delegate, controller, viewer) = try makeViewer()
        defer { controller.close() }
        try displayDocument(in: viewer)
        let rowsBefore = OperationCenter.shared.items.count
        let log = ViewerGraphicsExportAlertLog()
        delegate.finishViewerGraphicsExport(
            viewerController: viewer, content: .document, scope: .tracks, format: .pdf, bitmapScale: 1,
            outputURL: folder.appendingPathComponent("figure.pdf"), presentAlert: { log.alerts.append($0) }
        )
        viewer.viewerView.selectionRange = nil
        delegate.finishViewerGraphicsExport(
            viewerController: viewer, content: .document, scope: .selectedRegion, format: .pdf, bitmapScale: 1,
            outputURL: folder.appendingPathComponent("none.pdf"), presentAlert: { log.alerts.append($0) }
        )
        XCTAssertEqual(log.alerts.map(\.title), ["Export Successful", "Export Failed"])
        XCTAssertEqual(log.alerts.map(\.message), [
            "Successfully exported 1 graphic to figure.pdf.",
            "Failed to export viewer graphics: No selected region is available for export.",
        ])
        XCTAssertEqual(OperationCenter.shared.items.count, rowsBefore)
    }

    func testViewerGraphicsExportEndsAtTheRowWithNoSuccessAlert() async throws {
        let output = URL(fileURLWithPath: "/tmp/viewer-export.png")
        XCTAssertNil(AppDelegate.viewerGraphicsExportEndAlert(.completed(output)), "the completed row is the end")
        XCTAssertNil(AppDelegate.viewerGraphicsExportEndAlert(.cancelled), "a cancel shows nothing")
        let failed = AppDelegate.viewerGraphicsExportEndAlert(.failed(.init(message: "The region chr9:1-2 is unknown.")))
        XCTAssertEqual(failed?.title, "Export Failed")
        XCTAssertEqual(failed?.message, "Failed to export viewer graphics: The region chr9:1-2 is unknown.")

        let (delegate, controller, viewer) = try makeViewer()
        defer { controller.close() }
        try viewer.displayBundle(at: try makeBundle(), mode: .sequence(name: "chr1", restoreViewState: false))
        let content = AppDelegate.viewerGraphicsExportScopes(viewerController: viewer).content
        viewer.viewerView.selectionRange = 100..<300
        viewer.viewerView.isUserColumnSelection = false
        let reporter = RecordingOperationReporter()
        let log = ViewerGraphicsExportAlertLog()
        XCTAssertNil(delegate.finishViewerGraphicsExport(
            viewerController: viewer, content: content, scope: .selectedRegion, format: .png, bitmapScale: 2,
            outputURL: folder.appendingPathComponent("selection.png"), presentAlert: { log.alerts.append($0) },
            runner: trueRunner(), reporter: reporter
        ))
        XCTAssertEqual(log.alerts, [.noSelectedRegion])
        XCTAssertEqual(log.alerts.first?.message, "No selected region is available for export.")
        XCTAssertTrue(reporter.items.isEmpty, "an empty selection begins no row")

        let failing = try XCTUnwrap(delegate.finishViewerGraphicsExport(
            viewerController: viewer, content: content, scope: .tracks, format: .png, bitmapScale: 2,
            outputURL: folder.appendingPathComponent("tracks.png"), presentAlert: { log.alerts.append($0) },
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ))
        guard case .failed(let failure) = await failing.task.value else { return XCTFail("/usr/bin/false fails") }
        XCTAssertEqual(log.alerts.last, .failed(failure.message))
    }

    // MARK: - UX item 6 and BIO items 2, 3 and 6, what the app passes

    func testViewerGraphicsExportPassesTheViewerTheme() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(AppDelegate.viewerGraphicsExportTheme(for: dark), .dark)
        XCTAssertEqual(AppDelegate.viewerGraphicsExportTheme(for: light), .light)
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: 3000, pixelWidth: 800, sequenceLength: 3000)
        for (appearance, theme) in [(dark, "dark"), (light, "light")] {
            let settings = try AppDelegate.viewerGraphicsExportSettings(
                scope: .tracks, format: .pdf, bitmapScale: 2, frame: frame, boundsWidth: 800, userSelection: nil,
                appearance: appearance, alignment: nil
            )
            let arguments = ViewerGraphicExport.invocation(
                bundleURL: folder, settings: settings, outputURL: folder.appendingPathComponent("a.pdf"), force: false
            ).arguments()
            let index = try XCTUnwrap(arguments.firstIndex(of: "--theme"))
            XCTAssertEqual(arguments[index + 1], theme)
        }
    }

    func testViewerGraphicsExportPassesTheViewportWindowOneBased() throws {
        let frame = ReferenceFrame(chromosome: "chr1", start: 999.4, end: 2000.2, pixelWidth: 800, sequenceLength: 3000)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        func settings(
            _ scope: ViewerExportScope, _ format: ViewerGraphicFormat = .png, selection: Range<Int>? = nil,
            alignment: (excludeFlags: UInt16, coverageScale: CoverageScaleMode)? = nil
        ) throws -> ViewerGraphicExport.Settings {
            try AppDelegate.viewerGraphicsExportSettings(
                scope: scope, format: format, bitmapScale: 4, frame: frame, boundsWidth: 812, userSelection: selection,
                appearance: light, alignment: alignment
            )
        }
        let tracks = try settings(.tracks)
        XCTAssertEqual(tracks.region, "chr1:1000-2001")
        XCTAssertEqual(tracks.width, 812)
        XCTAssertFalse(tracks.includeRuler)
        XCTAssertEqual(tracks.scale, 4)
        XCTAssertTrue(try settings(.rulerAndTracks).includeRuler)
        let selected = try settings(.selectedRegion, selection: 500..<1500)
        XCTAssertEqual(selected.region, "chr1:1000-1500")
        XCTAssertFalse(selected.includeRuler)
        let minX = max(frame.leadingInset, min(frame.screenPosition(for: 500), frame.screenPosition(for: 1500)))
        let maxX = min(812 - frame.trailingInset, max(frame.screenPosition(for: 500), frame.screenPosition(for: 1500)))
        XCTAssertEqual(selected.width, Double(max(1, maxX - minX)), "the selection's width at the current zoom")
        XCTAssertThrowsError(try settings(.selectedRegion, selection: 2500..<2600)) {
            XCTAssertEqual($0 as? ViewerGraphicsExportNoSelection, ViewerGraphicsExportNoSelection())
        }
        XCTAssertThrowsError(try settings(.selectedRegion))
        XCTAssertNil(try settings(.tracks, .pdf).scale, "a PDF passes no --scale")
        let aligned = try settings(.tracks, alignment: (1796, .log10))
        XCTAssertEqual(aligned.excludeFlags, 1796)
        XCTAssertEqual(aligned.coverageScale, .log10)
    }
}
