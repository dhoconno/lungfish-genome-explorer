// ReferenceOpenManifestLoadTests.swift - A reference opens with one manifest decode, off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

/// Records every decode that `BundleLoadProbe` reports.
final class BundleDecodeLog: Sendable {
    private let entries = Mutex<[(kind: BundleLoadProbe.Kind, path: String)]>([])

    /// Records each later decode. With `offMainOnly`, a decode on the main
    /// thread stops the test process at that decode. With `held`, the manifest
    /// decode of that bundle waits on `gate` once it is recorded.
    func install(offMainOnly: Bool, holding held: URL? = nil, on gate: BundleDecodeGate? = nil) {
        let heldPath = held?.standardizedFileURL.path
        BundleLoadProbe.install { [self] kind, url in
            if offMainOnly {
                dispatchPrecondition(condition: .notOnQueue(.main))
            }
            let path = url.standardizedFileURL.path
            entries.withLock { $0.append((kind, path)) }
            if kind == .bundleManifest, path == heldPath {
                gate?.waitForRelease()
            }
        }
    }

    func count(_ kind: BundleLoadProbe.Kind) -> Int {
        entries.withLock { $0.filter { $0.kind == kind }.count }
    }

    /// The bundle or result folders decoded as `kind`, in the order the decodes began.
    func paths(_ kind: BundleLoadProbe.Kind) -> [String] {
        entries.withLock { $0.filter { $0.kind == kind }.map(\.path) }
    }
}

/// Records every name index and sequence reader that any bundle starts to build.
/// The seam traps the process at a build on the main queue.
final class SequenceIndexBuildLog: Sendable {
    private let builds = Mutex<[ReferenceBundleSequenceCache.Build]>([])

    func install() {
        ReferenceBundleSequenceCache.installBuildObserver { [self] build in
            dispatchPrecondition(condition: .notOnQueue(.main))
            builds.withLock { $0.append(build) }
        }
    }

    /// Records every build like `install()`, and parks the first name index build on `gate` once it is recorded,
    /// so the load that runs it holds the decode lane until the gate is released.
    func install(parkingFirstNameIndexOn gate: BundleDecodeGate) {
        ReferenceBundleSequenceCache.installBuildObserver { [self] build in
            dispatchPrecondition(condition: .notOnQueue(.main))
            let isFirstNameIndex = builds.withLock { list -> Bool in
                list.append(build)
                return build == .nameIndex && list.filter { $0 == .nameIndex }.count == 1
            }
            if isFirstNameIndex {
                gate.waitForRelease()
            }
        }
    }

    func count(_ build: ReferenceBundleSequenceCache.Build) -> Int {
        builds.withLock { $0.filter { $0 == build }.count }
    }
}

/// Records the manifest identifier of every browser summary build. The seam traps the
/// process at a build on the main queue (lane 12.37, PF10 note a).
final class BrowserSummaryBuildLog: Sendable {
    private let builds = Mutex<[String]>([])

    func install() {
        BrowserSummarySynthesisProbe.install { [self] identifier in
            dispatchPrecondition(condition: .notOnQueue(.main))
            builds.withLock { $0.append(identifier) }
        }
    }

    var identifiers: [String] { builds.withLock { $0 } }
}

/// The manifest of a large reference is hundreds of megabytes and takes
/// seconds to decode. Opening one decoded it three times on the main thread,
/// for the route, for the embedded viewer and for the BAM metadata context.
@MainActor
final class ReferenceOpenManifestLoadTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        BrowserSummarySynthesisProbe.install(nil)
        ReferenceBundleSequenceCache.installBuildObserver(nil)
        BundleDecodeLane.overrideLargeFileBytes(nil)
        try await super.tearDown()
    }

    func testReferenceOpenDecodesOnceOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenManifestLoad")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Open Once",
            chromosomes: [.init(name: "chr2", length: 80), .init(name: "chr1", length: 100)],
            in: root
        )
        let digestBefore = try TreeDigest.of(root)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?
                .testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == bundleURL.standardizedFileURL
        }
        XCTAssertTrue(opened, "the embedded viewer never opened the bundle")
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        XCTAssertEqual(viewport.testDisplayedSequenceNames.sorted(), ["chr1", "chr2"])
        XCTAssertEqual(decodes.count(.bundleManifest), 1)
        XCTAssertEqual(try TreeDigest.of(root), digestBefore, "opening a reference wrote to its folder (UX 6)")
    }

    /// PF10 note a and F5a (lane 12.37). A genome bundle whose `manifest.json` stores no browser summary opens
    /// with its summary built once, in the off-main load, and the open writes no mirror into its project (UX 6).
    func testOpenSynthesizesBrowserSummaryOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenSlimSummary")
        defer { TestTempDirectory.cleanup(root) }
        let projectURL = root.appendingPathComponent("Open.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Slim Summary",
            chromosomes: [.init(name: "chr2", length: 80), .init(name: "chr1", length: 100)],
            in: projectURL
        )
        try Self.removeStoredBrowserSummary(in: bundleURL)
        let digestBefore = try TreeDigest.of(root)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true)
        let summaryBuilds = BrowserSummaryBuildLog()
        summaryBuilds.install()

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?
                .testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == bundleURL.standardizedFileURL
        }
        XCTAssertTrue(opened, "the embedded viewer never opened the bundle")
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        XCTAssertEqual(viewport.testDisplayedSequenceNames.sorted(), ["chr1", "chr2"])
        XCTAssertEqual(decodes.count(.bundleManifest), 1)
        let manifest = try XCTUnwrap(viewport.currentInput?.manifest)
        XCTAssertEqual(summaryBuilds.identifiers, [manifest.identifier], "the open did not build its summary once")
        XCTAssertEqual(manifest.browserSummary?.sequences.map(\.name), ["chr2", "chr1"])
        XCTAssertEqual(try TreeDigest.of(root), digestBefore, "opening a slim reference wrote to its project (UX 6)")
    }

    /// Rewrites the bundle's `manifest.json` without its `browser_summary`, as `save` writes a new bundle.
    private static func removeStoredBrowserSummary(in bundleURL: URL) throws {
        let url = bundleURL.appendingPathComponent(BundleManifest.filename)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "browser_summary")
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    /// UX ruling Q-S1. The decode of a bundle the user has left still runs to
    /// its end, and its late result must leave only the new selection's rows.
    func testSupersededOpenCommitsOnlyTheNewSelection() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenSuperseded")
        defer { TestTempDirectory.cleanup(root) }
        let bundleA = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle A", chromosomes: [.init(name: "chrA1", length: 100)], in: root
        )
        let bundleB = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle B", chromosomes: [.init(name: "chrB1", length: 100)], in: root
        )
        let gate = BundleDecodeGate()
        defer { gate.release() }
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true, holding: bundleA, on: gate)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleA)
        let taskA = split.bundleOpenTask
        await waitUntil(timeout: .seconds(30)) { decodes.count(.bundleManifest) == 1 }
        split.displayReferenceBundleViewportFromSidebar(at: bundleB)

        let showsB = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?.testDisplayedSequenceNames == ["chrB1"]
        }
        XCTAssertTrue(showsB, "the newer selection never showed its rows")
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)

        gate.release()
        await taskA?.value

        XCTAssertTrue(split.viewerController.referenceBundleViewportController === viewport)
        XCTAssertEqual(viewport.testDisplayedSequenceNames, ["chrB1"])
        XCTAssertEqual(viewport.currentInput?.renderedBundleURL, bundleB.standardizedFileURL)
        let holdsB = await waitUntil(timeout: .seconds(30)) {
            viewport.testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == bundleB.standardizedFileURL
        }
        XCTAssertTrue(holdsB, "the embedded viewer does not hold the newer selection")
        XCTAssertEqual(
            decodes.paths(.bundleManifest),
            [bundleA, bundleB].map(\.standardizedFileURL.path)
        )
    }

    /// FIDX review fix 1. A cancelled open cannot stop its decode, but it skips the
    /// name index and `.fai` builds, which would hold the decode lane for seconds
    /// more before the commit guard drops the result. Only the newer selection builds.
    func testSupersededOpenSkipsItsIndexBuilds() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenSkipsIndexes")
        defer { TestTempDirectory.cleanup(root) }
        let bundleA = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle A", chromosomes: [.init(name: "chrA1", length: 100)], in: root
        )
        let bundleB = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle B", chromosomes: [.init(name: "chrB1", length: 100)], in: root
        )
        let gate = BundleDecodeGate()
        defer { gate.release() }
        let builds = SequenceIndexBuildLog()
        builds.install()
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true, holding: bundleA, on: gate)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleA)
        let taskA = split.bundleOpenTask
        await waitUntil(timeout: .seconds(30)) { decodes.count(.bundleManifest) == 1 }
        split.displayReferenceBundleViewportFromSidebar(at: bundleB)

        let showsB = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?.testDisplayedSequenceNames == ["chrB1"]
        }
        XCTAssertTrue(showsB, "the newer selection never showed its rows")

        gate.release()
        await taskA?.value

        XCTAssertEqual(builds.count(.nameIndex), 1, "the superseded open built its name index")
        XCTAssertEqual(builds.count(.reader), 1, "the superseded open built its sequence reader")
    }

    /// A reference open left for an item of another kind takes its
    /// "Loading …" toast down when its decode ends. No later load hides it.
    func testOpenSupersededByAnotherItemHidesItsToast() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenToast")
        defer { TestTempDirectory.cleanup(root) }
        let bundleA = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle A", chromosomes: [.init(name: "chrA1", length: 100)], in: root
        )
        let gate = BundleDecodeGate()
        defer { gate.release() }
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true, holding: bundleA, on: gate)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleA)
        let taskA = split.bundleOpenTask
        XCTAssertFalse(split.activityIndicator.isHidden, "the open shows no Loading toast")
        await waitUntil(timeout: .seconds(30)) { decodes.count(.bundleManifest) == 1 }

        _ = split.beginDisplayRequest(identity: split.contentSelectionIdentity(url: root, kind: "other"))
        split.viewerController.clearViewport()
        gate.release()
        await taskA?.value

        let hidden = await waitUntil(timeout: .seconds(30)) { split.activityIndicator.isHidden }
        XCTAssertTrue(hidden, "the superseded open left its Loading toast on screen")
        XCTAssertNil(split.viewerController.referenceBundleViewportController)
    }

    /// SWIFT-fai 4.7 item 1. The chromosome name index (250 ms) and the `.fai` of a
    /// reference with hundreds of thousands of sequences (seconds) were built by the
    /// embedded viewer's first lookup and first fetch, on the main actor. The open
    /// builds both in its off-main load, and the viewer shows that same bundle.
    func testOpenBuildsSequenceIndexesOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenIndexes")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Open Indexes",
            chromosomes: [.init(name: "chr2", length: 80), .init(name: "chr1", length: 100)],
            in: root
        )
        let builds = SequenceIndexBuildLog()
        builds.install()

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?
                .testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == bundleURL.standardizedFileURL
        }
        XCTAssertTrue(opened, "the embedded viewer never opened the bundle")
        let shown = try XCTUnwrap(
            split.viewerController.referenceBundleViewportController?.testEmbeddedViewerController.currentReferenceBundle
        )
        XCTAssertEqual(shown.sequenceCache.nameIndexBuildCount, 1)
        XCTAssertEqual(shown.sequenceCache.readerBuildCount, 1)
        XCTAssertEqual(builds.count(.nameIndex), 1, "a second bundle built its name index")
        XCTAssertEqual(builds.count(.reader), 1, "a second bundle built its sequence reader")
    }

    /// FIDX review fix 2, a pin that passes at its base. The decode lane holds one large decode at a time, and a
    /// large open's name index and `.fai` builds sit inside the same lane turn as its decode. While A is parked in
    /// its name index build, B waits for the lane and has not decoded its manifest. If `prepareSequenceAccess()`
    /// ever left the lane's work closure, B's decode would start during A's build and the first count would read 2.
    func testIndexBuildsHoldTheDecodeLane() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceIndexesHoldLane")
        defer { TestTempDirectory.cleanup(root) }
        let bundleA = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle A", chromosomes: [.init(name: "chrA1", length: 100)], in: root
        )
        let bundleB = try MappingRoutingFixture.makeReferenceBundle(
            name: "Bundle B", chromosomes: [.init(name: "chrB1", length: 100)], in: root
        )
        // Every manifest counts as large, so each decode waits for the lane.
        BundleDecodeLane.overrideLargeFileBytes(0)
        let gate = BundleDecodeGate()
        defer { gate.release() }
        let builds = SequenceIndexBuildLog()
        builds.install(parkingFirstNameIndexOn: gate)
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true)

        let taskA = Task { await MainSplitViewController.loadReferenceBundleOffMain(at: bundleA) }
        let parked = await waitUntil(timeout: .seconds(30)) { builds.count(.nameIndex) == 1 }
        XCTAssertTrue(parked, "A never reached its name index build")
        let taskB = Task { await MainSplitViewController.loadReferenceBundleOffMain(at: bundleB) }
        let queued = await waitUntil(timeout: .seconds(30)) { BundleDecodeLane.waitingCount == 1 }
        XCTAssertTrue(queued, "B did not wait for the lane while A built its indexes")
        XCTAssertEqual(decodes.count(.bundleManifest), 1, "B decoded its manifest during A's index build")

        gate.release()
        let resultA = await taskA.value
        let resultB = await taskB.value
        XCTAssertNoThrow(try resultA.get())
        XCTAssertNoThrow(try resultB.get())
        XCTAssertEqual(decodes.count(.bundleManifest), 2)
        XCTAssertEqual(builds.count(.nameIndex), 2)
    }
}
