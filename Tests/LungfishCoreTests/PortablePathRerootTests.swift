// PortablePathRerootTests.swift - Records written under another machine's project resolve into this one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// A record written before paths were made portable, or on another machine,
/// names the project root it was written under. When it is read from inside a
/// project that holds the same relative file, that path now reads as this
/// project's copy. A tail that does not exist here is left alone.
final class PortablePathRerootTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private let foreign = "/tmp/lge-demo-build/projects/Human Mapping and Variants (with results).lungfish"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-reroot-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("HG002 chr20.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try Data("@r\n".utf8).write(to: imports.appendingPathComponent("reads.fastq.gz"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Analyses/minimap2-1"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sidecar: URL { project.appendingPathComponent("Analyses/minimap2-1/.lungfish-provenance.json") }

    func testForeignProjectPathWithExistingTailRerootsIntoThisProject() throws {
        let json = """
        {"files":[{"path":"\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz"}],"argv":["minimap2","\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz"]}
        """
        let resolved = PortablePath.resolveJSON(Data(json.utf8), forFileAt: sidecar)
        let text = try XCTUnwrap(String(data: resolved, encoding: .utf8))
        let expected = project.standardizedFileURL.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        XCTAssertEqual(text.components(separatedBy: expected.replacingOccurrences(of: "/", with: "\\/")).count, 3, text)
        XCTAssertFalse(text.contains("lge-demo-build"), text)
    }

    func testForeignProjectPathWithoutMatchingTailIsLeftAlone() throws {
        let path = "\(foreign)/Imports/other.lungfishfastq/other.fastq.gz"
        let json = "{\"path\":\"\(path)\"}"
        let resolved = PortablePath.resolveJSON(Data(json.utf8), forFileAt: sidecar)
        XCTAssertEqual(resolved, Data(json.utf8))
    }

    func testPathInsideThisProjectIsUnchanged() throws {
        let path = project.appendingPathComponent("Imports/reads.lungfishfastq/reads.fastq.gz").path
        let text = PortablePath.rerootForeignProjectPaths(text: path, context: .forFile(at: sidecar))
        XCTAssertEqual(text, path)
    }
}
