// GeneiousImportAnnotationArgvTests.swift - The annotation record of import geneious names the command that ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27, ruling MD62. The default annotation importer of `lungfish-cli import geneious`
// attaches a track to each reference bundle it makes. Its record names the words the process was
// started with and never `lungfish-cli annotation-import`, which no leaf has. The test runs the
// importer the command builds on a bundle made without tools, in process, where the words are the
// test runner's own.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class GeneiousImportAnnotationArgvTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/GeneiousImportAnnotationArgv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testTheDefaultImporterRecordsTheWordsTheCommandWasStartedWith() async throws {
        let bundle = try SequenceEditFixture.referenceBundle(in: scratch.appendingPathComponent("bundle"))
        let bed = scratch.appendingPathComponent("features.bed")
        try "chr1\t2\t9\tfeatureA\t0\t+\n".write(to: bed, atomically: true, encoding: .utf8)

        _ = try await ImportCommand.GeneiousSubcommand.importService().annotationImporter(bed, bundle)

        let annotations = bundle.appendingPathComponent("annotations", isDirectory: true)
        let logName = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: annotations.path).first { $0.hasSuffix("-import-provenance.json") }
        )
        let log = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: annotations.appendingPathComponent(logName))) as? [String: Any]
        )
        let entry = try XCTUnwrap((log["entries"] as? [[String: Any]])?.first)
        let argv = try XCTUnwrap(entry["argv"] as? [String])
        XCTAssertEqual(argv, CommandLine.arguments)
        XCTAssertFalse(argv.contains("annotation-import"), "\(argv)")
        XCTAssertEqual(entry["toolName"] as? String, CLICommandIdentity.executableName)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertEqual(record.steps.first?.argv, CommandLine.arguments)
    }
}
