// FastqExportSampleBarcodesCommandTests.swift - lungfish-cli fastq export sample-barcodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M2, ARCH ruling on the export shape 1.1 row A13 and 1.3, BIO 6. The leaf writes the sheet
// from the selection file the app wrote, names only that file as its input, refuses before it writes, and parses the
// arguments the drawer's begin helper builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class FastqExportSampleBarcodesCommandTests: XCTestCase {
    private var folder: URL!
    private var fastq: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqExportSampleBarcodes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fastq = folder.appendingPathComponent("reads.fastq")
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: fastq)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let assignments = [
        FASTQSampleBarcodeAssignment(
            sampleID: "S1", sampleName: "Alpha", forwardBarcodeID: "BC01", forwardSequence: "acgt",
            reverseBarcodeID: "BC02", reverseSequence: "tgca", metadata: ["Batch": "b1", "Cohort": "case"]
        ),
        FASTQSampleBarcodeAssignment(sampleID: "S2", forwardBarcodeID: "BC03", reverseBarcodeID: "BC04"),
        FASTQSampleBarcodeAssignment(sampleID: "S2", sampleName: "Same id again", forwardBarcodeID: "BC05"),
    ]

    private func writeSelection(asymmetric: Bool = false, name: String = "selection.json") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FASTQSampleBarcodeExport.selection(assignments: Self.assignments, asymmetric: asymmetric).encoded().write(to: url)
        return url
    }

    private func command(_ arguments: [String]) throws -> FastqExportSampleBarcodesSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? FastqExportSampleBarcodesSubcommand)
    }

    private func leafArguments(tab: String = "samples", selection: URL, output: URL, extra: [String] = []) -> [String] {
        ["fastq", "export", "sample-barcodes", fastq.path, "--tab", tab, "--selection", selection.path, "--output", output.path] + extra
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    /// The sheet is the builder's text for the rows in the selection's order, repeated sample ids included.
    func testEachTabWritesTheSheetItsSymmetryCalls() throws {
        let expectations: [(tab: String, asymmetric: Bool, text: String)] = [
            ("samples", false, FASTQSampleBarcodeCSV.exportCSV(Self.assignments)),
            ("samples", true, FASTQSampleBarcodeCSV.exportCSV(Self.assignments)),
            ("demux", false, FASTQSampleBarcodeCSV.exportCSV(Self.assignments)),
            ("demux", true, FASTQSampleBarcodeCSV.exportAsymmetricCSV(Self.assignments)),
        ]
        for (index, expected) in expectations.enumerated() {
            let output = folder.appendingPathComponent("sheet-\(index).csv")
            let selection = try writeSelection(asymmetric: expected.asymmetric, name: "selection-\(index).json")
            _ = try command(leafArguments(tab: expected.tab, selection: selection, output: output)).export()
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), expected.text, "\(expected.tab) \(expected.asymmetric)")
        }
        XCTAssertTrue(FASTQSampleBarcodeCSV.exportCSV(Self.assignments).contains("S1,Alpha,BC01,ACGT,BC02,TGCA,b1,case"))
        XCTAssertEqual(
            FASTQSampleBarcodeExport.assignments(in: FASTQSampleBarcodeExport.selection(assignments: Self.assignments, asymmetric: false)),
            Self.assignments
        )
    }

    /// The record names the leaf, its canonical argv and the selection file with its digest, and nothing else. The
    /// FASTQ file is the drawer's subject and is never opened, so it is not an input.
    func testRecordNamesTheLeafAndTheSelectionFileOnly() throws {
        let selection = try writeSelection(asymmetric: true)
        let output = folder.appendingPathComponent("record.csv")
        let arguments = leafArguments(tab: "demux", selection: selection, output: output)
        _ = try command(arguments).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish fastq export sample-barcodes")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["selection.json"])
        XCTAssertTrue(inputs.allSatisfy { $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath", "selection", "tab"])
        XCTAssertEqual(envelope.options.explicit["tab"], .string("demux"))
        XCTAssertTrue(envelope.options.defaults.isEmpty)
        XCTAssertEqual(envelope.options.resolvedDefaults.keys.sorted(), ["assignmentCount", "asymmetricDemux"])
        XCTAssertEqual(envelope.options.resolvedDefaults["assignmentCount"], .integer(3))
        XCTAssertEqual(envelope.options.resolvedDefaults["asymmetricDemux"], .boolean(true))
        XCTAssertEqual(envelope.output?.format, .text)
    }

    func testRefusesAnExistingOutputUnlessForced() throws {
        let selection = try writeSelection()
        let output = folder.appendingPathComponent("exists.csv")
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try command(leafArguments(selection: selection, output: output)).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal)
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep")
        _ = try command(leafArguments(selection: selection, output: output, extra: ["--force"])).export()
        XCTAssertNotEqual(try String(contentsOf: output, encoding: .utf8), "keep")
        XCTAssertEqual(try Self.envelope(of: output).options.explicit["force"], .boolean(true))
    }

    /// Every refusal comes before any write, and a refusal leaves neither the output nor its record.
    func testRefusesBeforeWriting() throws {
        let good = try writeSelection()
        let garbage = folder.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        let rowWithoutValues = folder.appendingPathComponent("no-values.json")
        try ViewerExportSelection(identities: ["0"]).encoded().write(to: rowWithoutValues)
        let cases: [(name: String, arguments: (URL) -> [String])] = [
            ("a selection file that is missing", { self.leafArguments(selection: self.folder.appendingPathComponent("none.json"), output: $0) }),
            ("a selection file that is not JSON", { self.leafArguments(selection: garbage, output: $0) }),
            ("a row with no values", { self.leafArguments(selection: rowWithoutValues, output: $0) }),
            ("a FASTQ that is missing", { output in
                ["fastq", "export", "sample-barcodes", self.folder.appendingPathComponent("gone.fastq").path,
                 "--tab", "samples", "--selection", good.path, "--output", output.path]
            }),
            ("an output in a folder that is missing", { _ in
                self.leafArguments(selection: good, output: self.folder.appendingPathComponent("missing/out.csv"))
            }),
            ("an output that is the selection file", { _ in self.leafArguments(selection: good, output: good, extra: ["--force"]) }),
        ]
        for (index, refusal) in cases.enumerated() {
            let output = folder.appendingPathComponent("refused-\(index).csv")
            XCTAssertThrowsError(try command(refusal.arguments(output)).export(), refusal.name) { error in
                XCTAssertTrue(error is ViewerExportRefusal, "\(refusal.name): \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), refusal.name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), refusal.name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("missing").path))
        XCTAssertEqual(try Data(contentsOf: good), try FASTQSampleBarcodeExport.selection(assignments: Self.assignments, asymmetric: false).encoded())
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// canonical argv is the executable name and the same array.
    func testFastqExportLeafParsesTheGUIArguments() throws {
        let selection = try writeSelection()
        let invocation = FASTQSampleBarcodeExport.invocation(
            bundleURL: fastq, tab: .demux, selectionURL: selection,
            outputURL: folder.appendingPathComponent("gui.csv"), force: true
        )
        let arguments = invocation.arguments()
        let leaf = try command(arguments)
        XCTAssertEqual(leaf.invocation(), invocation)
        XCTAssertEqual(leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), FASTQSampleBarcodeExport.commandPath)
        XCTAssertEqual(FastqExportSampleBarcodesSubcommand.configuration.commandName, FASTQSampleBarcodeExport.commandPath.last)
        XCTAssertEqual(FastqExportSubcommand.configuration.commandName, FASTQSampleBarcodeExport.commandPath[1])
    }

    func testLeafRefusesAnOptionItDoesNotTakeAndAnUnknownTab() throws {
        let selection = try writeSelection()
        let output = folder.appendingPathComponent("refuse.csv")
        XCTAssertThrowsError(try command(leafArguments(selection: selection, output: output, extra: ["--sample", "S1"])))
        XCTAssertThrowsError(try command(leafArguments(tab: "primer-trim", selection: selection, output: output)))
        XCTAssertThrowsError(try command(["fastq", "export", "sample-barcodes", fastq.path, "--tab", "samples", "--output", output.path]))
    }
}
