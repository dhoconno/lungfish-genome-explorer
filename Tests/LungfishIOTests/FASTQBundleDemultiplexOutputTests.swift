// FASTQBundleDemultiplexOutputTests.swift - Every demultiplex run keeps its own directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class FASTQBundleDemultiplexOutputTests: XCTestCase {
    private var bundle: URL!

    override func setUpWithError() throws {
        bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-output-\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundle)
    }

    func testFirstRunOwnsDemuxAndLaterRunsAreNumbered() throws {
        let fm = FileManager.default
        XCTAssertEqual(FASTQBundle.nextDemultiplexOutputDirectory(in: bundle).lastPathComponent, "demux")
        try fm.createDirectory(at: bundle.appendingPathComponent("demux"), withIntermediateDirectories: true)
        XCTAssertEqual(FASTQBundle.nextDemultiplexOutputDirectory(in: bundle).lastPathComponent, "demux-2")
        try fm.createDirectory(at: bundle.appendingPathComponent("demux-2"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("demux-3"), withIntermediateDirectories: true)
        XCTAssertEqual(FASTQBundle.nextDemultiplexOutputDirectory(in: bundle).lastPathComponent, "demux-4")
        // The first run's directory is never touched.
        XCTAssertTrue(fm.fileExists(atPath: bundle.appendingPathComponent("demux").path))
    }

    func testListsRunDirectoriesInRunOrderAndIgnoresOtherNames() throws {
        let fm = FileManager.default
        for name in ["demux-10", "demux", "demux-2", "demuxed", "demux-x", "demux-1", "derivatives"] {
            try fm.createDirectory(at: bundle.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "not a directory".write(to: bundle.appendingPathComponent("demux-3"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            FASTQBundle.demultiplexOutputDirectories(in: bundle).map(\.lastPathComponent),
            ["demux", "demux-2", "demux-10"]
        )
    }

    func testOrdinalParsing() {
        XCTAssertEqual(FASTQBundle.demultiplexOutputOrdinal(of: "demux"), 1)
        XCTAssertEqual(FASTQBundle.demultiplexOutputOrdinal(of: "demux-2"), 2)
        XCTAssertEqual(FASTQBundle.demultiplexOutputOrdinal(of: "demux-12"), 12)
        XCTAssertNil(FASTQBundle.demultiplexOutputOrdinal(of: "demux-1"))
        XCTAssertNil(FASTQBundle.demultiplexOutputOrdinal(of: "demux-"))
        XCTAssertNil(FASTQBundle.demultiplexOutputOrdinal(of: "demux-output"))
        XCTAssertNil(FASTQBundle.demultiplexOutputOrdinal(of: "derivatives"))
    }

    func testMissingBundleListsNothing() {
        let missing = bundle.appendingPathComponent("missing.lungfishfastq")
        XCTAssertEqual(FASTQBundle.demultiplexOutputDirectories(in: missing), [])
        XCTAssertEqual(FASTQBundle.nextDemultiplexOutputDirectory(in: missing).lastPathComponent, "demux")
    }
}
