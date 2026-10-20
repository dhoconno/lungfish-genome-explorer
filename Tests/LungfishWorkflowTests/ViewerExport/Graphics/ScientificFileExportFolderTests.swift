// ScientificFileExportFolderTests.swift - The staged-folder transaction of a bulk viewer export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2), MANAGER 3. The bulk form of `bundle export-graphic` writes one folder of figures
// with one record that names every figure as an output, published once, and a cancel leaves no folder.

import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class ScientificFileExportFolderTests: XCTestCase {
    private var scratch: URL!
    private var root: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "ExportFolder")
        // Four levels below the scratch folder, so the provenance lookup never lists the user temp folder (QA review Fix 3).
        root = scratch.appendingPathComponent("levels/deep/run/case", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    private func request(sources: [URL], folder: URL) -> ScientificFileExportProvenance.Request {
        .cliLeaf(
            workflowName: "lungfish bundle export-graphic", sourceURLs: sources, outputURL: folder,
            outputFormat: FileFormat(rawValue: "png"), argv: ["lungfish-cli", "bundle", "export-graphic"],
            resolved: ["figureCount": .integer(2)], runClock: ProvenanceRunClock()
        )
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".export.tmp") }
    }

    func testAFolderIsPublishedOnceWithOneRecordNamingEveryFile() throws {
        let input = root.appendingPathComponent("regions.bed")
        try "chr1\t0\t10\n".write(to: input, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("figures", isDirectory: true)
        let sidecar = try ScientificFileExportProvenance.writeFolderAtomically(request(sources: [input], folder: folder)) { staged in
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            try Data("first".utf8).write(to: staged.appendingPathComponent("a.png"))
            try Data("second".utf8).write(to: staged.appendingPathComponent("b.png"))
            return ["a.png", "b.png"]
        }
        XCTAssertEqual(sidecar.lastPathComponent, ProvenanceRecorder.provenanceFilename)
        XCTAssertEqual(sidecar.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let outputs = envelope.files.filter { $0.role == .output }
        XCTAssertEqual(outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["a.png", "b.png"])
        XCTAssertEqual(envelope.outputs.count, 2)
        for output in outputs {
            let published = folder.appendingPathComponent(URL(fileURLWithPath: output.path).lastPathComponent)
            XCTAssertEqual(output.checksumSHA256, try ProvenanceFileHasher.sha256(of: published))
        }
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["regions.bed"])
        XCTAssertEqual(inputs.first?.checksumSHA256, try ProvenanceFileHasher.sha256(of: input))
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.options.resolvedDefaults["figureCount"], .integer(2))
        XCTAssertEqual(try leftovers(), [])
        // ARCH review Fix 4. The lookup `provenance verify` uses finds the folder's record from the folder and from
        // a figure in it.
        XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: folder))
        XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: folder.appendingPathComponent("a.png")))
    }

    func testAThrowLeavesNoFolderNoRecordAndNoStagedFolder() throws {
        let folder = root.appendingPathComponent("figures", isDirectory: true)
        XCTAssertThrowsError(try ScientificFileExportProvenance.writeFolderAtomically(request(sources: [], folder: folder)) { staged in
            try Data("first".utf8).write(to: staged.appendingPathComponent("a.png"))
            throw CancellationError()
        }) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try leftovers(), [])
    }

    /// ARCH review Fix 1. On the default APFS volume `A.png` and `a.png` are one file, and so are a precomposed and a
    /// decomposed letter, so two names that differ only so are refused and nothing is published.
    func testNamesThatDifferOnlyInCaseAreRefusedAndLeaveNothing() throws {
        let cases: [(written: String, names: [String])] = [
            ("A.png", ["A.png", "a.png"]),
            ("caf\u{E9}.png", ["caf\u{E9}.png", "CAFE\u{301}.png"]),
        ]
        for (index, item) in cases.enumerated() {
            let folder = root.appendingPathComponent("figures-\(index)", isDirectory: true)
            XCTAssertThrowsError(try ScientificFileExportProvenance.writeFolderAtomically(request(sources: [], folder: folder)) { staged in
                try Data("first".utf8).write(to: staged.appendingPathComponent(item.written))
                return item.names
            }, "case \(index)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "case \(index)")
            XCTAssertEqual(try leftovers(), [], "case \(index)")
        }
    }

    func testAnExistingFolderIsRefusedAndKept() throws {
        let folder = root.appendingPathComponent("figures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let kept = folder.appendingPathComponent("kept.png")
        try Data("kept".utf8).write(to: kept)
        XCTAssertThrowsError(try ScientificFileExportProvenance.writeFolderAtomically(request(sources: [], folder: folder)) { _ in
            XCTFail("an existing folder is refused before any write")
            return []
        })
        XCTAssertEqual(try Data(contentsOf: kept), Data("kept".utf8))
        XCTAssertEqual(try leftovers(), [])
    }
}
