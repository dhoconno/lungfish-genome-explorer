// ReferenceCopySequencesPreparedBundleTests.swift - Copy Sequences fetches from the bundle the open prepared
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M4, FIDX review fix 3 (docs/plans/2026-10-17-phase-2-12-pre-fixes/reviews/FIDX-T1.md). The
// open builds the reference's bundle, its chromosome name index and its `.fai` reader once, off the main actor.
// `copyReferenceSequences` made its data provider with no bundle, so the first fetch of every Copy Sequences built a
// second bundle with a second name index and a second `.fai` parse. The provider now shares the prepared bundle.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishOperations
import LungfishTestSupport

@MainActor
final class ReferenceCopySequencesPreparedBundleTests: XCTestCase {
    override func tearDown() async throws {
        ReferenceBundleSequenceCache.installBuildObserver(nil)
        try await super.tearDown()
    }

    /// Opens a reference, runs the sequence list's Copy Sequences for both rows, and counts the builds. The open
    /// builds one name index and one reader, and the copy builds none, and copies each sequence in full with the bytes
    /// the provider of the old path fetches.
    func testCopySequencesBuildsNoSecondBundleOrIndex() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceCopyPrepared")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Copy Prepared",
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
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        let rows = viewport.testSequenceTableView.displayedRows
        XCTAssertEqual(rows.map(\.summary.name).sorted(), ["chr1", "chr2"])
        XCTAssertEqual(builds.count(.nameIndex), 1, "the open builds one name index")
        XCTAssertEqual(builds.count(.reader), 1, "the open builds one sequence reader")

        // Copy Sequences writes the general pasteboard, so the test puts back what it found.
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        let marker = "copy-sequences-\(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        let copy = try XCTUnwrap(viewport.testSequenceTableView.onCopySequences)
        copy(rows, false)
        let copied = await waitUntil(timeout: .seconds(30)) { pasteboard.string(forType: .string) != marker }
        XCTAssertTrue(copied, "Copy Sequences never wrote the pasteboard")
        let copiedText = pasteboard.string(forType: .string)

        XCTAssertEqual(builds.count(.nameIndex), 1, "Copy Sequences built a second name index")
        XCTAssertEqual(builds.count(.reader), 1, "Copy Sequences built a second sequence reader")

        // The bytes (review 12.34 fix 5). The provider the copy used before the fix has no shared bundle, so it builds
        // its own and reads the same rows. The copy has to equal what it fetches, row by row in the order of the rows
        // and joined by a line feed. It runs after the build counts above, which it would raise. The fixture's index
        // points each record at its header line, so the fetched text holds header bytes, and the test compares bytes
        // without assuming what they are.
        let manifest = try BundleManifest.load(from: bundleURL)
        let unshared = BundleDataProvider(bundleURL: bundleURL, manifest: manifest)
        var fetched: [String] = []
        for row in rows {
            let length = Int(row.summary.length)
            fetched.append(try await unshared.fetchSequence(chromosome: row.summary.name, start: 0, end: length))
        }
        XCTAssertEqual(fetched.map(\.count), rows.map { Int($0.summary.length) }, "each sequence in full")
        XCTAssertEqual(
            copiedText, fetched.joined(separator: "\n"), "the bytes of both sequences, in the order of the rows"
        )
    }
}
