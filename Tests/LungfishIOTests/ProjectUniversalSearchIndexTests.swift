// ProjectUniversalSearchIndexTests.swift - What an incremental index update reads again
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishIO

/// The viewer writes a reference bundle's `.viewstate.json` after every pan or zoom pause. The
/// manifest of a large bundle runs to hundreds of megabytes and indexing the bundle decodes all of
/// it, so a view state write must not send the bundle back through the indexer.
final class ProjectUniversalSearchIndexTests: XCTestCase {

    private var projectURL: URL!
    private var bundleURL: URL!
    private var index: ProjectUniversalSearchIndex!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectUniversalSearchIndexTests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = projectURL.appendingPathComponent("Ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = BundleManifest(
            name: "Ref",
            identifier: "org.test.index.ref",
            source: SourceInfo(organism: "Fixture", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 100,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 100, offset: 0, lineBases: 80, lineWidth: 81)]
            )
        )
        try manifest.save(to: bundleURL)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent(BundleViewState.filename))
        index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        try index.rebuild()
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    func testViewStateChangeDoesNotReindexBundle() throws {
        var indexed: [String] = []
        index.onFolderIndexed = { indexed.append($0.lastPathComponent) }
        let viewState = bundleURL.appendingPathComponent(BundleViewState.filename)
        // The save is an atomic write, which puts a temporary file beside the target first. The watcher
        // reports that name as well, so a save delivers both paths.
        let viewStateTemp = bundleURL.appendingPathComponent("\(BundleViewState.filename).sb-e7881877-TeusD9")

        try index.update(changedPaths: [viewState])
        XCTAssertEqual(indexed, [], "A view state write sent the bundle back through the indexer.")

        try index.update(changedPaths: [viewState, viewStateTemp])
        XCTAssertEqual(indexed, [], "The temporary file of a view state write sent the bundle back through the indexer.")

        // The seam does count. A change to the manifest indexes the bundle once, with or without the
        // view state beside it.
        try index.update(changedPaths: [bundleURL.appendingPathComponent("manifest.json"), viewState])
        XCTAssertEqual(indexed, ["Ref.lungfishref"])
    }
}
