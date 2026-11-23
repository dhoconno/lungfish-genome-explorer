// ViewSwitchViewStateDrivers+Reference.swift - The reference (k08) and mapping result (k22) keep their place and look
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-state phase, lane VS-REF. Each kind runs a person's change, a switch away and back, a relaunch on the same
// injected store, and three changed bundles (a shorter sequence, a renamed sequence, a gone sequence). Each case reads
// the view's own controls, the visible range and the row height, never the kept state. `ViewSwitchViewStateTests` and
// its coverage table come with VS-CORE item 3, which folds these cases into it.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class ViewSwitchViewStateReferenceTests: XCTestCase {
    private enum Kind: CaseIterable { case reference, mapping }

    private typealias Sequence = MappingRoutingFixture.Chromosome
    private static let original: [Sequence] = [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)]
    private static let yourPlace = "The data changed since your last visit, so your place was not kept."

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

    func testSwitchAwayAndBackKeepsThePlaceAndTheLook() async throws {
        for kind in Kind.allCases {
            let store = makeStore()
            let left = try await openAndChange(kind, store: store)
            let other = try await open(kind, bundle: try bundle("Other", Self.original), store: store)
            other.testEmbeddedViewerController.clearBundleDisplay()
            try await assertKept(left, in: try await open(kind, bundle: try bundle("Kept", Self.original), store: store), kind)
        }
    }

    func testRelaunchKeepsThePlaceAndTheLook() async throws {
        for kind in Kind.allCases {
            let store = makeStore()
            let left = try await openAndChange(kind, store: store)
            store.flushSynchronously()
            let relaunched = ViewMemoryStore(root: store.root)
            try await assertKept(left, in: try await open(kind, bundle: try bundle("Kept", Self.original), store: relaunched), kind)
        }
    }

    func testAShorterSequenceDropsThePlaceAndSaysSo() async throws {
        try await assertChangedBundleDropsThePlace([.init(name: "chr1", length: 4_000), .init(name: "chr2", length: 3_000)])
    }

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

    // MARK: - Drivers

    private struct Left {
        let chromosome: String
        let start: Double
        let end: Double
    }

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
    private func openAndChange(_ kind: Kind, store: ViewMemoryStore) async throws -> Left {
        let viewer = try await open(kind, bundle: try bundle("Kept", Self.original), store: store).testEmbeddedViewerController
        XCTAssertTrue(viewer.navigateToPosition(chromosome: "chr1", start: 1_000, end: 1_600))
        viewer.annotationDisplayHeight = 30
        viewer.viewerView.annotationHeight = 30
        viewer.zoomIn() // a user event handler, which marks the view changed
        let frame = try XCTUnwrap(viewer.referenceFrame)
        let left = Left(chromosome: frame.chromosome, start: frame.start, end: frame.end)
        viewer.clearBundleDisplay()
        return left
    }

    private func assertKept(_ left: Left, in viewport: ReferenceBundleViewportController, _ kind: Kind) async throws {
        let viewer = viewport.testEmbeddedViewerController
        let frame = try XCTUnwrap(viewer.referenceFrame)
        XCTAssertEqual(frame.chromosome, left.chromosome, "\(kind) came back on its sequence")
        XCTAssertEqual(frame.start, left.start, accuracy: 0.5, "\(kind) came back at its place")
        XCTAssertEqual(frame.end, left.end, accuracy: 0.5, "\(kind) came back at its zoom")
        XCTAssertEqual(viewer.viewerView.annotationHeight, 30, "\(kind) came back with its row height")
        XCTAssertNil(resetLine(in: viewer), "\(kind) lost nothing, so no line shows")
    }

    /// Keeps a place on chr1, changes the bundle in place, and requires the place dropped with "your place".
    private func assertChangedBundleDropsThePlace(_ changed: [Sequence]) async throws {
        for kind in Kind.allCases {
            let store = makeStore()
            _ = try await openAndChange(kind, store: store)
            let viewer = try await open(kind, bundle: try bundle("Kept", changed), store: store).testEmbeddedViewerController
            let frame = try XCTUnwrap(viewer.referenceFrame)
            XCTAssertEqual(frame.start, 0, "\(kind) opened at the start of its first sequence")
            XCTAssertEqual(frame.end, Double(frame.sequenceLength), "\(kind) opened its first sequence whole")
            XCTAssertEqual(viewer.viewerView.annotationHeight, 30, "\(kind) kept its row height, which needs no data key")
            XCTAssertEqual(resetLine(in: viewer), Self.yourPlace, "\(kind) says the place was not kept")
            try FileManager.default.removeItem(at: root.appendingPathComponent("Kept.lungfishref"))
        }
    }

    private func resetLine(in viewer: ViewerViewController) -> String? {
        viewer.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first?.words
    }
}
