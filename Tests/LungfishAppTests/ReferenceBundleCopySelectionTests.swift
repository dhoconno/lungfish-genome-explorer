// ReferenceBundleCopySelectionTests.swift - Command-C on a selection in a reference bundle copies the selected bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport

/// Probe of the trust session, lane PROBES-C, row BEEPS-COPY-SAYS-NO-SEQUENCE.
///
/// `SequenceViewerView.setReferenceBundle` clears `sequence` because a bundle view fetches the bases it draws on
/// demand into `cachedBundleSequence`, and `copySelectionToClipboard` refuses with "The viewer holds no sequence"
/// when `sequence` is nil. This test opens a reference bundle through `ViewerViewController.displayReferenceBundle`
/// (the route the app takes), lets the draw land the bases on screen, selects a range and presses Command-C
/// through `keyDown`, the route a Command-C takes in the viewer. It reads the pasteboard and the words shown.
@MainActor
final class ReferenceBundleCopySelectionTests: XCTestCase {
    @MainActor
    private final class Recorder: ViewerRefusalPresenting {
        private(set) var reports: [FailureReport] = []

        func present(_ report: FailureReport, in window: NSWindow?) {
            reports.append(report)
        }
    }

    private let chromosome = "chr1"
    /// 20,000 bases from a fixed generator, longer than the 10 kb opening window and with no repeat a wrong slice could match.
    private let bases: String = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let letters = Array("ACGT")
        return String((0..<20_000).map { _ -> Character in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return letters[Int((state >> 33) % 4)]
        })
    }()
    private var retainedController: ViewerViewController?
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ReferenceBundleCopySelection")
    }

    override func tearDown() async throws {
        retainedController = nil
        TestTempDirectory.cleanup(root)
        root = nil
        try await super.tearDown()
    }

    func testCommandCOnASelectionOfAReferenceBundleCopiesTheSelectedBases() async throws {
        let bundleURL = try makeReferenceBundle()
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let controller = ViewerViewController()
        controller.loadView()
        // `SequenceViewerView.viewController` is weak, so the test keeps the owner alive.
        retainedController = controller
        // The viewer the window sizes, opened on the bundle as `displayReferenceBundle` opens it.
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        viewer.viewController = controller
        viewer.setReferenceBundle(bundle)
        // The person zooms in to 60 bases, where each base has a letter on screen.
        controller.referenceFrame = ReferenceFrame(
            chromosome: chromosome, start: 0, end: 60, pixelWidth: 800, sequenceLength: bases.count
        )
        // The annotation cache covers the chromosome, so the draw starts only the sequence fetch.
        viewer.cachedAnnotationRegion = GenomicRegion(chromosome: chromosome, start: 0, end: bases.count)
        viewer.cachedBundleAnnotations = []
        viewer.layoutSubtreeIfNeeded()

        // The draw starts the fetch, and the bases it lands are the ones the screen shows.
        let rep = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: rep)
        let shown = await waitUntil(budget: .lookup) { viewer.cachedBundleSequence != nil }
        XCTAssertTrue(shown, "the viewer never fetched the bases of the bundle")

        // A drag over bases 10 up to 20 (0-based, end excluded), and Command-C.
        let selection = 10..<20
        let expected = String(Array(bases)[selection])
        XCTAssertTrue(
            viewer.cachedBundleSequence?.contains(expected) == true,
            "the viewer holds the bases it shows, so a selection of them can be copied"
        )
        viewer.selectionRange = selection

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        viewer.copyPasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("sentinel-before-copy", forType: .string)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
            context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        let recorder = Recorder()
        ViewerRefusalSeam.$presenter.withValue(recorder) { viewer.keyDown(with: event) }
        await waitUntil(budget: .standard) {
            pasteboard.string(forType: .string) == expected || !recorder.reports.isEmpty
        }

        let copied = pasteboard.string(forType: .string)
        let words = recorder.reports.map(\.whatHappened)
        // Measured at the base d38e16ad8 before the fix: the pasteboard kept its sentinel and the viewer said "The viewer
        // holds no sequence, so there was nothing to copy." while the bases showed.
        XCTAssertEqual(copied, expected, "Command-C on bases 10 to 20 of a shown reference left the pasteboard with \(copied ?? "nothing"); words shown: \(words)")
        XCTAssertTrue(words.isEmpty, "a copy that worked shows no refusal, but the viewer said \(words)")
    }

    /// Edit > Copy is the standard `copy:` action. The viewer did not answer it, so the item stayed greyed out in the
    /// viewer and only the key reached the copy.
    func testEditCopyOnASelectionOfAReferenceBundleCopiesTheSelectedBases() async throws {
        let (viewer, expected) = try await makeViewerShowingBases(selecting: 30..<45)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        viewer.copyPasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("sentinel-before-copy", forType: .string)

        let answered = viewer.tryToPerform(#selector(NSText.copy(_:)), with: nil)

        XCTAssertTrue(answered, "the viewer answers the Edit > Copy action, so the menu item is enabled in it")
        XCTAssertEqual(pasteboard.string(forType: .string), expected, "Edit > Copy on bases 30 to 45 left the pasteboard unchanged")
    }

    /// With a bundle open and no region on screen to take, a copy with nothing selected says to select bases. It said
    /// the viewer holds no sequence, which the open bundle contradicts.
    func testCopyWithNothingSelectedInAReferenceBundleSaysToSelectBases() throws {
        let bundleURL = try makeReferenceBundle()
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        viewer.setReferenceBundle(bundle)
        let recorder = Recorder()

        ViewerRefusalSeam.$presenter.withValue(recorder) { viewer.copySelectionToClipboard() }

        XCTAssertEqual(recorder.reports.count, 1, "one refusal is shown")
        let report = try XCTUnwrap(recorder.reports.first)
        XCTAssertFalse(report.whatHappened.contains("holds no sequence"), report.whatHappened)
        XCTAssertTrue(report.whatHappened.contains("No bases are selected"), report.whatHappened)
        XCTAssertTrue(report.nextStep.contains("Select the bases you want"), report.nextStep)
    }

    // MARK: - Fixture

    /// A viewer opened on the fixture bundle and zoomed to 60 bases, with the fetch landed and `selection` selected.
    /// It returns the viewer and the bases the selection covers.
    private func makeViewerShowingBases(selecting selection: Range<Int>) async throws -> (SequenceViewerView, String) {
        let bundleURL = try makeReferenceBundle()
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let controller = ViewerViewController()
        controller.loadView()
        retainedController = controller
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        viewer.viewController = controller
        viewer.setReferenceBundle(bundle)
        controller.referenceFrame = ReferenceFrame(
            chromosome: chromosome, start: 0, end: 60, pixelWidth: 800, sequenceLength: bases.count
        )
        viewer.cachedAnnotationRegion = GenomicRegion(chromosome: chromosome, start: 0, end: bases.count)
        viewer.cachedBundleAnnotations = []
        viewer.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: rep)
        let shown = await waitUntil(budget: .lookup) { viewer.cachedBundleSequence != nil }
        XCTAssertTrue(shown, "the viewer never fetched the bases of the bundle")
        viewer.selectionRange = selection
        return (viewer, String(Array(bases)[selection]))
    }


    private func makeReferenceBundle() throws -> URL {
        let bundleURL = root.appendingPathComponent("copy.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        let header = ">\(chromosome)\n"
        try "\(header)\(bases)\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        let offset = header.utf8.count
        try "\(chromosome)\t\(bases.count)\t\(offset)\t\(bases.count)\t\(bases.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Copy Selection Reference",
            identifier: "org.lungfish.tests.copy-selection",
            source: SourceInfo(organism: "Test organism", assembly: "copy-selection"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(bases.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosome,
                        length: Int64(bases.count),
                        offset: Int64(offset),
                        lineBases: bases.count,
                        lineWidth: bases.count + 1
                    )
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
