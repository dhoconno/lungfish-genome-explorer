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
}
