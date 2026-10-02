// PrimerOrderExportProvenanceParityTests.swift - A GUI primer order records the export-order command it runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The primer analysis viewport exports an order through PrimerOrderExportService
// and records `lungfish-cli primers analysis export-order` in the Operations
// panel. Its provenance used to record the app process's own launch arguments
// (R3, R8). These tests run the GUI path and the recorded command on one saved
// Primer3 analysis and compare the orders and the provenance argv.

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class PrimerOrderExportProvenanceParityTests: XCTestCase {
    func testGUIOrderRecordsTheRowCommandAsArgvAndTheCommandWritesTheSameOrder() async throws {
        let fixture = try makePrimer3Fixture(pairCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let pairIDs = snapshot.designReview.filter { $0.presentation == .primer3Template }.map(\.id)
        let selection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot,
            scope: .primer3CandidatePairs(includedPairIDs: [try XCTUnwrap(pairIDs.last)])
        )
        let draft = PrimerOrderDraft(
            selection: selection,
            oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
            defaultName: "fixture candidate pairs order"
        )
        let metadata = PrimerOrderMetadata(name: "Pair order", requestedBy: "Bench", notes: "Rush")

        // The GUI path, with the argv the viewport now passes.
        let guiDestination = fixture.root.appendingPathComponent("GUI order")
        let guiArgv = MainSplitViewController.primerOrderExportProvenanceArgv(
            draft: draft, metadata: metadata, destinationURL: guiDestination
        )
        let guiOutput = try await PrimerOrderExportService().export(
            selection: draft.selection, metadata: metadata, destinationURL: guiDestination, invocationArgv: guiArgv
        )
        let guiRow = try XCTUnwrap(MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: guiDestination
        ))
        let gui = try PrimerOrderExportService.loadSnapshot(from: guiOutput)
        XCTAssertEqual(
            gui.provenance.argv,
            [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: guiRow)),
            "the provenance names the export-order command the Operations row records"
        )
        XCTAssertNotEqual(gui.provenance.argv, CommandLine.arguments)

        // The same command, recorded for a second folder, run through the real CLI.
        let cliDestination = fixture.root.appendingPathComponent("CLI order")
        let cliRow = try XCTUnwrap(MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: cliDestination
        ))
        let command = try RecordedCLICommand.parse(cliRow, as: PrimerAnalysisExportOrderCommand.self)
        try await command.run()
        let cli = try PrimerOrderExportService.loadSnapshot(from: cliDestination)

        XCTAssertEqual(cli.document.oligos, gui.document.oligos)
        XCTAssertEqual(cli.document.metadata, gui.document.metadata)
        XCTAssertEqual(cli.document.selection.selectedAssayIDs, gui.document.selection.selectedAssayIDs)
        XCTAssertEqual(cli.provenance.workflowName, gui.provenance.workflowName)
    }

    /// A saved Primer3 analysis with `pairCount` candidate pairs, the fixture
    /// PrimerAnalysisExportOrderCommandTests writes.
    private func makePrimer3Fixture(pairCount: Int) throws -> (root: URL, bundle: URL) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let analysisID = UUID(), runID = UUID(), inputID = UUID(), resultID = UUID()
        let template = "ACGTACGT"
        let input = root.appendingPathComponent("input.fasta")
        try Data(">\(inputID.uuidString)\n\(template)\n".utf8).write(to: input)
        let native = root.appendingPathComponent("native.txt")
        try Data("Synthetic Primer3 fixture, not an engine execution.\n".utf8).write(to: native)
        func oligo(start: Int, end: Int, orientation: String, sequence: String) -> [String: Any] {
            ["id": UUID().uuidString, "start": start, "end": end, "orientation": orientation,
             "sequence": sequence, "meltingTemperature": 60.0, "gcPercent": 50.0]
        }
        let pairs: [[String: Any]] = (0..<pairCount).map { index in
            ["id": UUID().uuidString, "productSize": 8 - index,
             "left": oligo(start: 0, end: 2, orientation: "forward", sequence: "AC"),
             "right": oligo(start: 6 - index, end: 8 - index, orientation: "reverse", sequence: index == 0 ? "AC" : "GT")]
        }
        let result: [String: Any] = [
            "resultID": resultID.uuidString, "inputID": inputID.uuidString,
            "title": "Synthetic display fixture", "sourceKind": "fasta",
            "sourceIndex": 0, "sourceRecordID": "synthetic-display-fixture",
            "templateSequence": template, "excludedRegions": [], "pairs": pairs,
            "explanation": "Synthetic candidate fixture.",
        ]
        let document: [String: Any] = ["schemaVersion": 1, "analysisID": analysisID.uuidString,
            "runID": runID.uuidString, "results": [result]]
        let normalized = root.appendingPathComponent("normalized.json")
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: normalized)
        let path = "results/primer3-normalized-v1.json"
        let artifacts: [PrimerAnalysisSourceArtifact] = [
            .init(sourceURL: input, relativePath: "inputs/\(inputID.uuidString).fasta", role: "input", format: "fasta"),
            .init(sourceURL: native, relativePath: "native/output.txt", role: "nativeOutput", format: "text"),
            .init(sourceURL: normalized, relativePath: path, role: "normalized", format: "json"),
        ]
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: analysisID, runID: runID, grouping: .independent,
            inputs: [.init(id: inputID, label: "Fixture", artifactPaths: ["inputs/\(inputID.uuidString).fasta"])],
            results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [path])],
            artifacts: artifacts, destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
            invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        let physicalBundle = try XCTUnwrap(realpath(bundle.url.path, nil))
        defer { free(physicalBundle) }
        return (root, URL(fileURLWithPath: String(cString: physicalBundle)))
    }
}
