// SidebarScanSnapshotParityTests.swift - characterization tests for the off-main sidebar scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// F5/F7: the sidebar tree build moved off the main actor. The recursive
// filesystem walk now produces an immutable `SidebarScanNode` value tree
// (nonisolated, Sendable, no AppKit) which is materialized into the
// `SidebarItem` graph on the main actor.
//
// These tests are CHARACTERIZATION tests: they pin the exact tree structure a
// representative fixture project produces, so the refactor is provably
// behavior-preserving. They assert on titles, types, subtitles, URLs, badge
// intent and child ordering at every level.

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class SidebarScanSnapshotParityTests: XCTestCase {

    private var tempRoot: URL!
    private var projectURL: URL!

    /// Creates the fixture project in a fresh temp directory and registers cleanup.
    ///
    /// Done per-test rather than in `setUpWithError` because the XCTest setup hooks
    /// are nonisolated, and this suite (like the sidebar itself) is `@MainActor`.
    private func makeFixtureProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarScanParity-\(UUID().uuidString)", isDirectory: true)
        tempRoot = root
        projectURL = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try buildFixtureProject()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Fixture

    /// Builds a project directory exercising the tree-build paths that F5/F7 flagged:
    /// plain folders/files, a FASTQ bundle with a demux child and a derivative,
    /// standalone NAO-MGS and NVD result bundles, an `Analyses/` folder holding a
    /// single-run and a classifier batch directory, and hidden/sidecar files that
    /// must be filtered out.
    private func buildFixtureProject() throws {
        let fm = FileManager.default

        // --- Plain folders and files at the project root.
        let imports = projectURL.appendingPathComponent("Imports", isDirectory: true)
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        try "ACGT".write(to: projectURL.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try ">s\nACGT\n".write(to: imports.appendingPathComponent("sample.fasta"), atomically: true, encoding: .utf8)

        // Sidecars that must be filtered out of the tree.
        try "{}".write(to: imports.appendingPathComponent("sample.lungfish-meta.json"), atomically: true, encoding: .utf8)
        try "idx".write(to: imports.appendingPathComponent("sample.fai"), atomically: true, encoding: .utf8)
        try "ds".write(to: imports.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        // A `provenance` folder at the project root must be excluded there.
        try fm.createDirectory(
            at: projectURL.appendingPathComponent("provenance", isDirectory: true),
            withIntermediateDirectories: true
        )

        // --- A FASTQ bundle with a demux child and a derivative child.
        let bundle = imports.appendingPathComponent("run1.lungfishfastq", isDirectory: true)
        try makeFASTQBundle(at: bundle)

        let demuxChild = bundle
            .appendingPathComponent("demux", isDirectory: true)
            .appendingPathComponent("barcode01.lungfishfastq", isDirectory: true)
        try makeFASTQBundle(at: demuxChild)

        // A `materialized/` directory inside demux/ must be skipped by the scan.
        try fm.createDirectory(
            at: bundle.appendingPathComponent("demux/materialized", isDirectory: true),
            withIntermediateDirectories: true
        )

        // --- Standalone NAO-MGS and NVD result bundles inside Imports/.
        let naomgs = imports.appendingPathComponent("naomgs-alpha", isDirectory: true)
        try fm.createDirectory(at: naomgs, withIntermediateDirectories: true)
        try #"{"sampleName":"Alpha","createdAt":"2026-01-01T00:00:00Z"}"#
            .write(to: naomgs.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let nvd = imports.appendingPathComponent("nvd-beta", isDirectory: true)
        try fm.createDirectory(at: nvd, withIntermediateDirectories: true)
        try #"{"experiment":"Beta","sampleCount":3}"#
            .write(to: nvd.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        // --- Analyses/ folder with a single kraken2 run and an esviritu batch.
        let analyses = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let single = analyses.appendingPathComponent("kraken2-2026-01-02T03-04-05", isDirectory: true)
        try fm.createDirectory(at: single, withIntermediateDirectories: true)
        try #"{"config":{"databaseName":"Viral DB"}}"#
            .write(to: single.appendingPathComponent("classification-result.json"), atomically: true, encoding: .utf8)

        let batch = analyses.appendingPathComponent("esviritu-batch-2026-01-02T03-04-06", isDirectory: true)
        for sample in ["sampleA", "sampleB"] {
            let dir = batch.appendingPathComponent(sample, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"virusCount":2}"#
                .write(to: dir.appendingPathComponent("esviritu-result.json"), atomically: true, encoding: .utf8)
        }
    }

    private func makeFASTQBundle(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try "@r\nACGT\n+\nIIII\n".write(
            to: url.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Snapshot rendering

    /// Renders a sidebar tree into a stable, diffable text snapshot.
    ///
    /// Captures everything the outline view actually displays: indentation-encoded
    /// structure, title, item type, subtitle, whether a custom badge image was
    /// rendered, the routing `userInfo`, and the project-relative URL.
    private func snapshot(_ items: [SidebarItem]) -> String {
        var lines: [String] = []

        func encode(_ item: SidebarItem, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let relativeURL = item.url.map { url -> String in
                let path = url.standardizedFileURL.path
                let root = projectURL.standardizedFileURL.path
                return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            } ?? "-"
            let userInfo = item.userInfo
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            lines.append(
                """
                \(indent)\(item.title) | type=\(item.type) | icon=\(item.icon ?? "-") \
                | badge=\(item.customImage != nil) | subtitle=\(item.subtitle ?? "-") \
                | userInfo=[\(userInfo)] | url=\(relativeURL)
                """
            )
            for child in item.children {
                encode(child, depth: depth + 1)
            }
        }

        for item in items {
            encode(item, depth: 0)
        }
        return lines.joined(separator: "\n")
    }

    private func openedSidebar() -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.openProject(at: projectURL)
        addTeardownBlock { @MainActor in sidebar.closeProject() }
        return sidebar
    }

    // MARK: - Characterization

    /// Pins the full tree the fixture project produces. If the refactor changes any
    /// title, type, ordering, subtitle, badge or routing key, this fails with a diff.
    func testFixtureProjectTreeSnapshotIsStable() throws {
        try makeFixtureProject()
        let sidebar = openedSidebar()
        let actual = snapshot(sidebar.rootItems)

        let expected = """
        Analyses | type=Folder | icon=flask | badge=false | subtitle=- | userInfo=[accessibilityIdentifier=sidebar-group-analyses] | url=/Analyses
          esviritu-batch-2026-01-02T03-04-06 | type=Batch Operation | icon=- | badge=true | subtitle=2 samples · 2026-01-02T03-04-06 | userInfo=[] | url=/Analyses/esviritu-batch-2026-01-02T03-04-06
          kraken2-2026-01-02T03-04-05 | type=Classification Result | icon=- | badge=true | subtitle=Classification (Viral DB) | userInfo=[analysisTool=kraken2] | url=/Analyses/kraken2-2026-01-02T03-04-05
        Imports | type=Folder | icon=folder | badge=false | subtitle=- | userInfo=[] | url=/Imports
          run1 | type=FASTQ Bundle | icon=doc.text | badge=false | subtitle=- | userInfo=[] | url=/Imports/run1.lungfishfastq
            barcode01 | type=FASTQ Bundle | icon=doc.text | badge=false | subtitle=- | userInfo=[] | url=/Imports/run1.lungfishfastq/demux/barcode01.lungfishfastq
          sample.fasta | type=Sequence | icon=doc.text | badge=false | subtitle=- | userInfo=[] | url=/Imports/sample.fasta
          NAO-MGS | type=NAO-MGS Surveillance Result | icon=- | badge=true | subtitle=- | userInfo=[] | url=/Imports/naomgs-alpha
          NVD | type=NVD Classification Result | icon=- | badge=true | subtitle=- | userInfo=[] | url=/Imports/nvd-beta
        notes.txt | type=Document | icon=doc.plaintext | badge=false | subtitle=- | userInfo=[] | url=/notes.txt
        """

        XCTAssertEqual(actual, expected, "Sidebar tree structure changed:\n\nACTUAL:\n\(actual)\n\nEXPECTED:\n\(expected)")
    }

    /// The scan filters internal sidecars, `.DS_Store`, index files, the root
    /// `provenance/` folder, and the `materialized/` demux staging directory.
    func testScanFiltersSidecarsAndStagingDirectories() throws {
        try makeFixtureProject()
        let sidebar = openedSidebar()
        let rendered = snapshot(sidebar.rootItems)

        for hidden in [".DS_Store", "sample.fai", "sample.lungfish-meta.json", "provenance", "materialized"] {
            XCTAssertFalse(rendered.contains(hidden), "Sidebar tree must not surface \(hidden)")
        }
    }

    /// A second scan of an unchanged project must yield a byte-identical snapshot.
    /// This guards against ordering nondeterminism creeping in when the walk moves
    /// off the main actor (e.g. concurrent child scans applied out of order).
    func testRepeatedScansProduceIdenticalSnapshots() throws {
        try makeFixtureProject()
        let sidebar = openedSidebar()
        let first = snapshot(sidebar.rootItems)

        sidebar.reloadFromFilesystem()
        let second = snapshot(sidebar.rootItems)

        XCTAssertEqual(first, second, "Repeated sidebar scans must be deterministic")
    }

    // MARK: - Off-main scan parity

    /// The background scan must produce the same value tree as the one the
    /// synchronous reload materializes. This is the actual F5/F7 parity check:
    /// the tree the user sees after a watcher-driven refresh is identical to the
    /// tree an inline scan would have produced.
    func testBackgroundScanMatchesSynchronousScan() async throws {
        try makeFixtureProject()
        let sidebar = openedSidebar()
        let synchronous = snapshot(sidebar.rootItems)

        let projectURL = self.projectURL!
        let scannedOffMain = await Task.detached(priority: .userInitiated) {
            SidebarProjectScanner.scanRootNodes(from: projectURL)
        }.value

        // Materializing off-main scan results on the main actor must reproduce
        // the exact same SidebarItem graph.
        let rebuilt = snapshot(materializeForTest(scannedOffMain))
        XCTAssertEqual(rebuilt, synchronous, "Off-main scan must match the synchronous scan exactly")
    }

    /// The scanner is a stateless namespace, so concurrent scans of the same
    /// project must all agree. Guards against shared mutable state sneaking in.
    func testConcurrentScansAgree() async throws {
        try makeFixtureProject()
        let projectURL = self.projectURL!

        let results = await withTaskGroup(of: [SidebarScanNode].self) { group in
            for _ in 0..<8 {
                group.addTask(priority: .userInitiated) {
                    SidebarProjectScanner.scanRootNodes(from: projectURL)
                }
            }
            var collected: [[SidebarScanNode]] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let reference = try XCTUnwrap(results.first)
        for result in results.dropFirst() {
            XCTAssertEqual(result, reference, "Concurrent sidebar scans must produce identical trees")
        }
    }

    /// Materializes scan nodes the same way the controller does, so the test can
    /// compare an off-main scan against the controller's own output.
    private func materializeForTest(_ nodes: [SidebarScanNode]) -> [SidebarItem] {
        nodes.map { node in
            let item: SidebarItem
            switch node.badge {
            case .text(let text):
                item = SidebarItem(
                    title: node.title,
                    type: node.type,
                    customImage: TextBadgeIcon.image(text: text, size: NSSize(width: 16, height: 16)),
                    children: materializeForTest(node.children),
                    url: node.url,
                    subtitle: node.subtitle
                )
            case .symbol(let name):
                item = SidebarItem(
                    title: node.title,
                    type: node.type,
                    icon: name,
                    children: materializeForTest(node.children),
                    url: node.url,
                    subtitle: node.subtitle
                )
            case nil:
                item = SidebarItem(
                    title: node.title,
                    type: node.type,
                    children: materializeForTest(node.children),
                    url: node.url,
                    subtitle: node.subtitle
                )
            }
            item.userInfo = node.userInfo
            return item
        }
    }

    // MARK: - Stale-scan guard

    /// A background scan that finishes AFTER a newer synchronous reload must be
    /// discarded rather than overwriting the fresher tree.
    ///
    /// This is the deterministic regression test for the generation guard. The
    /// race is forced rather than hoped for: the watcher-driven background reload
    /// is started while the project still contains `stale-marker.txt`, then the
    /// file is deleted and a synchronous reload installs the newer tree — all
    /// before the background scan's apply step can run. Without the generation
    /// re-check, the late scan reinstates the deleted file's row.
    func testStaleBackgroundScanDoesNotClobberNewerSynchronousReload() async throws {
        try makeFixtureProject()
        let staleMarker = projectURL.appendingPathComponent("stale-marker.txt")
        try "stale".write(to: staleMarker, atomically: true, encoding: .utf8)

        let sidebar = openedSidebar()
        XCTAssertTrue(
            sidebar.rootItems.contains { $0.title == "stale-marker.txt" },
            "Precondition: the marker file should be in the initial tree"
        )

        // Hold the background scan AFTER it has read the filesystem but BEFORE it
        // applies. `arrived` fires once the read is done (so the scan definitely
        // captured the marker), and `release` lets the stale apply proceed. This
        // makes the ordering deterministic instead of timing-dependent.
        let gate = ScanGate()
        SidebarViewController.scanBarrierForTesting = { await gate.arriveAndWait() }
        addTeardownBlock { SidebarViewController.scanBarrierForTesting = nil }

        // Start the background reload directly (bypassing the scheduler's debounce)
        // while the marker still exists, so the scan observes the OLD tree.
        let staleScan = sidebar.reloadFromFilesystemAsync(notifyUnchangedSelectionRefresh: false)

        // Wait until the scan has finished reading — only then is its result truly
        // "the old tree", which is what makes this a stale result rather than a
        // coincidentally-correct one.
        await gate.waitForArrival()

        // Delete the marker and install the newer tree synchronously. This bumps
        // the scan generation, so the held background scan is now stale.
        try FileManager.default.removeItem(at: staleMarker)
        sidebar.reloadFromFilesystem()
        XCTAssertFalse(
            sidebar.rootItems.contains { $0.title == "stale-marker.txt" },
            "The synchronous reload should have dropped the deleted marker"
        )

        // Release the stale scan and let it attempt its apply.
        await gate.release()
        await staleScan?.value

        XCTAssertFalse(
            sidebar.rootItems.contains { $0.title == "stale-marker.txt" },
            "A background scan that completes after a newer reload must be discarded, not applied"
        )
    }

    /// Rendezvous used to hold a background scan between its filesystem read and
    /// its main-actor apply.
    ///
    /// `arriveAndWait` is called by the scan; `waitForArrival` lets the test block
    /// until the scan has definitely finished reading; `release` unblocks it.
    private actor ScanGate {
        private var hasArrived = false
        private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            hasArrived = true
            let pendingArrivals = arrivalWaiters
            arrivalWaiters.removeAll()
            for continuation in pendingArrivals {
                continuation.resume()
            }
            await wait()
        }

        func waitForArrival() async {
            if hasArrived { return }
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }

        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    /// Closing a project while a background scan is in flight must not repopulate
    /// the sidebar. `closeProject` bumps the scan generation, and the apply step
    /// re-checks it on the main actor before touching `rootItems`.
    func testCloseProjectDiscardsInFlightBackgroundScan() async throws {
        try makeFixtureProject()
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.openProject(at: projectURL)
        XCTAssertFalse(sidebar.rootItems.isEmpty, "Fixture project should populate the sidebar")

        // Kick off a watcher-style background reload, then immediately close the
        // project before the scan can land.
        sidebar.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
        sidebar.closeProject()

        // Let any in-flight scan and its apply step run to completion.
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(
            sidebar.rootItems.isEmpty,
            "A background scan that completes after closeProject must not repopulate the sidebar"
        )
        XCTAssertNil(sidebar.projectFolderURL)
    }

    /// A watcher-driven reload must converge on the correct tree even though the
    /// scan now runs off the main actor.
    func testBackgroundReloadEventuallyAppliesTree() async throws {
        try makeFixtureProject()
        let sidebar = openedSidebar()
        let expected = snapshot(sidebar.rootItems)

        // Drop the tree, then let the debounced watcher path rebuild it.
        sidebar.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)

        var applied = ""
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(25))
            applied = snapshot(sidebar.rootItems)
            if applied == expected { break }
        }

        XCTAssertEqual(applied, expected, "Background reload must apply the same tree the synchronous scan builds")
    }
}
