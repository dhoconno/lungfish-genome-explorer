// ViewSwitchViewStateDrivers+Reference.swift - The reference (k08) and mapping result (k22) keep their place and look
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-state phase, lane VS-REF. `ReferenceViewStateDriver` runs k08 and k22 in ViewSwitchViewStateTests' real
// window: a person's change, a switch away and back, a relaunch, and a shorter sequence. It reads the embedded viewer's
// own controls, the visible range and the row height, never the kept state. `ViewSwitchViewStateReferenceTests` adds
// what the fixture's one sequence cannot show: a renamed and a gone sequence of a bundle with two, and the start clamp
// that Extract the visible region reads (VS B2).

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

/// The words of the one line when a changed bundle drops the place (VS U2, word 2).
private let yourPlaceWasNotKept = "The data changed since your last visit, so your place was not restored."

/// The reference and mapping result kinds, which show one embedded viewer on the fixture's one SARS-CoV-2 sequence.
@MainActor
struct ReferenceViewStateDriver: ViewStateDriver {
    enum Route { case reference, mapping }

    let route: Route
    var kind: String { route == .reference ? "Reference" : "Mapping result" }

    /// The fixture's one sequence (`RoutingSafetyNetFixtures.sarsCoV2ReferenceBundle`) and its length after a change.
    private static let sequence = "MT192765.1"
    private static let shorterLength: Int64 = 20_000

    /// The viewer the reference surface embeds, while it shows this route.
    func viewer(in harness: ViewSwitchWindowHarness) -> ViewerViewController? {
        guard let viewport = (harness.split.viewerController.installedSurface as? ReferenceBundleSurface)?.controller,
              let input = viewport.currentInput, (input.kind == .mappingResult) == (route == .mapping) else { return nil }
        return viewport.testEmbeddedViewerController
    }

    /// Shown once the viewer has a frame on the bundle and its restore has run.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        guard let viewer = viewer(in: harness) else { return false }
        return viewer.currentBundleURL != nil && viewer.referenceFrame != nil && viewer.viewMemory?.applied == true
    }

    /// Zooms into the sequence and makes the rows taller, as a person does, and lets the half second's debounce keep
    /// it. A switch inside that half second is the surface's leave, which VS-MAP owns (VS-REF Finding 2).
    func change(in harness: ViewSwitchWindowHarness) async throws {
        let viewer = try XCTUnwrap(viewer(in: harness))
        XCTAssertTrue(viewer.navigateToPosition(chromosome: Self.sequence, start: 1_000, end: 1_600))
        viewer.annotationDisplayHeight = 30
        viewer.viewerView.annotationHeight = 30
        viewer.zoomIn() // a user event handler, which marks the view changed
        let kept = await waitUntil(budget: .standard, pollInterval: .milliseconds(25)) {
            viewer.viewStateSaveWorkItem == nil
        }
        XCTAssertTrue(kept, "\(kind): the debounce kept the change")
    }

    /// The sequence, the visible range and the row height.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let viewer = try XCTUnwrap(viewer(in: harness))
        let frame = try XCTUnwrap(viewer.referenceFrame)
        return [
            "sequence \(frame.chromosome)",
            "start \(Int(frame.start.rounded()))",
            "end \(Int(frame.end.rounded()))",
            "row height \(Int(viewer.viewerView.annotationHeight))",
        ]
    }

    /// Writes the viewer bundle's manifest with its one sequence shorter, as a rebuilt bundle would.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let item = try XCTUnwrap(fixture.item.url)
        let bundle = try route == .reference ? item : XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "lungfishref" },
            "\(kind): the result holds its viewer bundle")
        let manifest = try BundleManifest.load(from: bundle)
        let genome = try XCTUnwrap(manifest.genome)
        let shorter = genome.chromosomes.map {
            ChromosomeInfo(
                name: $0.name, length: Self.shorterLength, offset: $0.offset, lineBases: $0.lineBases,
                lineWidth: $0.lineWidth)
        }
        try BundleManifest(
            name: manifest.name, identifier: manifest.identifier, source: manifest.source,
            genome: GenomeInfo(
                path: genome.path, indexPath: genome.indexPath, totalLength: Self.shorterLength, chromosomes: shorter),
            variants: manifest.variants, alignments: manifest.alignments
        ).save(to: bundle)
    }

    /// The kept place names a length the sequence no longer has, so it opens whole (VS B2). The row height needs no
    /// data key and comes back.
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        ["sequence \(Self.sequence)", "start 0", "end \(Self.shorterLength)", changed[3]]
    }

    var lineAfterChangedBundle: String? { yourPlaceWasNotKept }

    /// The line over the embedded viewer, which the viewer draws itself.
    func resetLineWords(in harness: ViewSwitchWindowHarness) -> String? {
        viewer(in: harness)?.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first?.words
    }
}

/// The changed bundles that need a bundle of two sequences, and the start clamp of VS B2.
@MainActor
final class ViewSwitchViewStateReferenceTests: XCTestCase {
    private enum Kind: CaseIterable { case reference, mapping }

    private typealias Sequence = MappingRoutingFixture.Chromosome
    private static let original: [Sequence] = [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)]

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ViewStateReference")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - Cases

    func testARenamedSequenceDropsThePlaceAndSaysSo() async throws {
        try await assertChangedBundleDropsThePlace([.init(name: "chrA", length: 5_000), .init(name: "chr2", length: 3_000)])
    }

    func testAGoneSequenceDropsThePlaceAndSaysSo() async throws {
        try await assertChangedBundleDropsThePlace([.init(name: "chr2", length: 3_000)])
    }

    /// VS B2. A kept start past the end of a sequence of the same name and length clamps to its last base, so Extract
    /// the visible region never gets a start past the sequence (`ViewerViewController+Extraction.swift:341-346`).
    func testARestoredFrameNeverGivesExtractAStartPastTheSequence() async throws {
        let store = makeStore()
        let bundleURL = try bundle("Kept", Self.original)
        let item = ViewMemoryItem.read(at: bundleURL)
        store.loadLoose()
        let key = try XCTUnwrap(store.key(for: item))
        let display = ReferenceViewerDisplay(BundleViewState.default)
        store.keep(
            ReferenceViewerMemory(
                display: display, locus: ViewMemoryLocus(sequenceName: "chr1", sequenceLength: 5_000, start: 7_000, end: 9_000)),
            startingView: ReferenceViewerMemory(display: display, locus: nil), for: key, dataKey: nil, folder: item.folder)

        let viewer = try await open(.reference, bundle: bundleURL, store: store).testEmbeddedViewerController
        let frame = try XCTUnwrap(viewer.referenceFrame)
        XCTAssertEqual(frame.chromosome, "chr1")
        XCTAssertEqual(frame.start, 4_999, "the kept start clamps to the last base")
        XCTAssertEqual(frame.end, 5_000, "the kept end clamps to the length")
        let extractStart = max(0, Int(frame.start))
        XCTAssertLessThan(extractStart, frame.sequenceLength, "Extract the visible region starts inside the sequence")
        XCTAssertNil(resetLine(in: viewer), "a clamp alone draws no line")
    }

    // MARK: - Support

    private func makeStore() -> ViewMemoryStore {
        ViewMemoryStore(root: root.appendingPathComponent("view-memory-\(UUID().uuidString)", isDirectory: true))
    }

    /// The bundle named `name` under the root, written in place so its folder keeps its identity.
    private func bundle(_ name: String, _ sequences: [Sequence]) throws -> URL {
        try MappingRoutingFixture.makeReferenceBundle(name: name, chromosomes: sequences, in: root)
    }

    /// Shows the bundle as `kind`, through the viewport's own route, and waits for the restore.
    private func open(_ kind: Kind, bundle: URL, store: ViewMemoryStore) async throws -> ReferenceBundleViewportController {
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view
        let viewer = viewport.testEmbeddedViewerController
        viewer.viewMemoryStore = store
        switch kind {
        case .reference:
            try viewport.configureForTesting(input: .directBundle(bundleURL: bundle, manifest: try BundleManifest.load(from: bundle)))
        case .mapping:
            let manifest = try BundleManifest.load(from: bundle)
            let result = root.appendingPathComponent("mapping-\(manifest.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            let contigs = (manifest.genome?.chromosomes ?? []).enumerated().map { index, sequence in
                MappingContigSummary(
                    contigName: sequence.name, contigLength: Int(sequence.length), mappedReads: 90 - index * 10,
                    mappedReadPercent: Double(90 - index * 10), meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60,
                    meanIdentity: 0.99)
            }
            viewport.configureForTesting(
                result: MappingRoutingFixture.makeMappingResult(resultDirectory: result, viewerBundleURL: bundle, contigs: contigs),
                resultDirectoryURL: result)
        }
        let shown = await waitUntil(budget: .lookup) {
            viewer.currentBundleURL?.standardizedFileURL == bundle.standardizedFileURL && viewer.viewMemoryIsSettled
        }
        XCTAssertTrue(shown, "\(bundle.lastPathComponent) was not shown as \(kind).")
        return viewport
    }

    /// Opens the kept bundle, zooms into chr1 and makes the rows taller, as a person does, and leaves it.
    private func openAndChange(_ kind: Kind, store: ViewMemoryStore) async throws {
        let viewer = try await open(kind, bundle: try bundle("Kept", Self.original), store: store).testEmbeddedViewerController
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr1", start: 1_000, end: 1_600))
        viewer.annotationDisplayHeight = 30
        viewer.viewerView.annotationHeight = 30
        viewer.zoomIn() // a user event handler, which marks the view changed
        viewer.clearBundleDisplay()
    }

    /// Keeps a place on chr1, changes the bundle in place, and requires the place dropped with "your place".
    private func assertChangedBundleDropsThePlace(_ changed: [Sequence]) async throws {
        for kind in Kind.allCases {
            let store = makeStore()
            try await openAndChange(kind, store: store)
            let viewer = try await open(kind, bundle: try bundle("Kept", changed), store: store).testEmbeddedViewerController
            let frame = try XCTUnwrap(viewer.referenceFrame)
            XCTAssertEqual(frame.start, 0, "\(kind) opened at the start of its first sequence")
            XCTAssertEqual(frame.end, Double(frame.sequenceLength), "\(kind) opened its first sequence whole")
            XCTAssertEqual(viewer.viewerView.annotationHeight, 30, "\(kind) kept its row height, which needs no data key")
            XCTAssertEqual(resetLine(in: viewer), yourPlaceWasNotKept, "\(kind) says the place was not kept")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Kept.lungfishref"))
        }
    }

    private func resetLine(in viewer: ViewerViewController) -> String? {
        viewer.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first?.words
    }
}
