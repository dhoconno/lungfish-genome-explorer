// MetadataExportOutputTests.swift - lungfish-cli metadata export --output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling on the export shape 1.1 and 1.6, row B12. `--output` writes the CSV and its
// record in one transaction, takes the folder's resolved metadata or a selection file for its rows, refuses before it
// writes, and leaves standard output alone. MetadataExportCLIGUIParityReplayTests runs the built command behind the
// app's row and cancels it through the real transport.

import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
import LungfishWorkflow

final class MetadataExportOutputTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-export-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A folder with two bundles and a folder-level samples.csv, whose rows the resolved metadata reads.
    private func makeFolder() throws -> URL {
        let folder = scratch.appendingPathComponent("RunFolder", isDirectory: true)
        for name in ["A", "B"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(name).lungfishfastq", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try "sample_name,sample_type,host\nA,stool,human\nB,swab,\"mouse, lab\"\n"
            .write(to: folder.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
        return folder
    }

    private func envelope(of output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
    }

    private func inputNames(of record: ProvenanceEnvelope) -> [String] {
        record.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
    }

    func testOutputWritesTheResolvedFolderMetadataWithItsRecord() throws {
        let folder = try makeFolder()
        let output = scratch.appendingPathComponent("out.csv")
        let outcome = try MetadataExportSubcommand.parse([folder.path, "--output", output.path]).export()

        XCTAssertEqual(outcome.outputURL.standardizedFileURL, output.standardizedFileURL)
        let resolved = FASTQFolderMetadata.loadResolved(from: folder)
        let expected = FASTQSampleMetadata.serializeMultiSampleCSV(resolved.sampleOrder.compactMap { resolved.samples[$0] })
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), expected)
        XCTAssertTrue(expected.contains("A,stool,human"), expected)

        let record = try envelope(of: output)
        XCTAssertEqual(record.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(record.tool.kind, "cli")
        XCTAssertEqual(record.workflowName, FolderMetadataExport.workflowName)
        XCTAssertEqual(record.argv, [
            CLICommandIdentity.executableName, "metadata", "export", folder.standardizedFileURL.path,
            "--output", output.standardizedFileURL.path,
        ])
        XCTAssertEqual(inputNames(of: record), ["samples.csv"], "the record names the files the loader read")
        XCTAssertEqual(record.options.resolvedDefaults["sampleCount"], .integer(2))
    }

    func testSelectionRowsReplaceTheFolderFilesAndAreTheOnlyInput() throws {
        let folder = try makeFolder()
        let output = scratch.appendingPathComponent("out.csv")
        var edited = FASTQSampleMetadata(sampleName: "A")
        edited.sampleType = "edited, \"quoted\""
        edited.customFields["Batch"] = "b1"
        let selectionURL = try FolderMetadataExport.selection(samples: [edited]).write(besideOutput: output)

        _ = try MetadataExportSubcommand.parse([
            folder.path, "--selection", selectionURL.path, "--output", output.path,
        ]).export()

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), FASTQSampleMetadata.serializeMultiSampleCSV([edited]))
        let record = try envelope(of: output)
        XCTAssertEqual(inputNames(of: record), [ViewerExportSelection.fileName])
        XCTAssertEqual(Set(record.options.explicit.keys), ["folder", "outputPath", "selection"])
    }

    func testASelectionRoundTripsEverySampleField() throws {
        var sample = FASTQSampleMetadata(sampleName: " Padded ")
        sample.sampleType = " stool "
        sample.notes = "line one\nline two, \"quoted\""
        sample.attachments = ["a.pdf"]
        sample.customFields = ["Batch": "b1", "Cohort": " case "]
        let other = FASTQSampleMetadata(sampleName: "Other")
        let selection = try FolderMetadataExport.selection(samples: [sample, other])
        XCTAssertEqual(selection.identities, ["0", "1"])
        XCTAssertEqual(FolderMetadataExport.samples(in: selection), [sample, other])
        XCTAssertNil(FolderMetadataExport.samples(in: ViewerExportSelection(identities: ["0"])), "a row with no sample")
    }

    func testAnExistingOutputIsRefusedUnlessForced() throws {
        let folder = try makeFolder()
        let output = scratch.appendingPathComponent("out.csv")
        try "old".write(to: output, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MetadataExportSubcommand.parse([folder.path, "--output", output.path]).export()) {
            XCTAssertTrue($0 is ViewerExportRefusal, "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "old", "a refusal leaves the file")

        _ = try MetadataExportSubcommand.parse([folder.path, "--output", output.path, "--force"]).export()
        XCTAssertNotEqual(try String(contentsOf: output, encoding: .utf8), "old")
        XCTAssertTrue(try envelope(of: output).argv.contains("--force"))
    }

    func testARefusalBeforeTheWriteLeavesNoOutput() throws {
        let folder = try makeFolder()
        let output = scratch.appendingPathComponent("out.csv")
        let refused = [
            [folder.path, "--output", output.path, "--format", "tsv"],
            [scratch.appendingPathComponent("missing").path, "--output", output.path],
            [folder.path, "--selection", scratch.appendingPathComponent("none.json").path, "--output", output.path],
            [folder.path, "--output", folder.appendingPathComponent("samples.csv").path, "--force"],
        ]
        for arguments in refused {
            XCTAssertThrowsError(try MetadataExportSubcommand.parse(arguments).export(), "\(arguments)") {
                XCTAssertTrue($0 is ViewerExportRefusal, "\($0)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSelectionOrForceWithoutOutputIsAUsageError() throws {
        let folder = try makeFolder()
        XCTAssertThrowsError(try MetadataExportSubcommand.parse([folder.path, "--force"]))
        XCTAssertThrowsError(try MetadataExportSubcommand.parse([folder.path, "--selection", "selection.json"]))
        let plain = try MetadataExportSubcommand.parse([folder.path])
        XCTAssertNil(plain.outputPath, "no --output keeps the standard output path")
    }
}
