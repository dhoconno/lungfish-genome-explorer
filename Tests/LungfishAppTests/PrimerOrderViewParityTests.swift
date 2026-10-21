// PrimerOrderViewParityTests.swift - The order folder of a PrimalScheme draft by its view
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A67 M1 pin and M2 parity. A PrimalScheme order exports the oligos its view displays.
// At the base the pin shows what the order folder holds for the default view and for a view with one
// primer hidden, which the CLI could not name (cli-parity-gap primer-order-export-custom-view).

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import XCTest
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class PrimerOrderViewParityTests: XCTestCase {
    func testTheOrderFolderHoldsTheOligosItsViewDisplays() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let primers = snapshot.designReview.filter { $0.presentation == .schemeReference }.flatMap(\.primers)
        let hidden = try XCTUnwrap(primers.first).id

        let defaultSelection = try PrimerOrderExportService.captureSelection(snapshot: snapshot, scope: .displayed)
        let defaultFolder = try await export(defaultSelection, to: fixture.root.appendingPathComponent("default order"))

        let settings = PrimerAnalysisDisplaySettings(hiddenPrimerIDs: [hidden])
        let filteredSelection = try PrimerOrderExportService.captureSelection(
            snapshot: snapshot, scope: .displayed, settings: settings)
        let filteredFolder = try await export(filteredSelection, to: fixture.root.appendingPathComponent("filtered order"))

        XCTAssertEqual(defaultSelection.selectedPrimerIDs.count, primers.count)
        XCTAssertEqual(filteredSelection.selectedPrimerIDs.count, primers.count - 1)
        XCTAssertFalse(filteredSelection.selectedPrimerIDs.contains(hidden))
        XCTAssertEqual(filteredSelection.settings, settings)
        // Both views write the same files, and the hidden primer's row is the one that goes.
        let names = try FileManager.default.contentsOfDirectory(atPath: defaultFolder.path).sorted()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: filteredFolder.path).sorted(), names)
        XCTAssertTrue(names.contains("order.json") && names.contains("ordering.csv"), "\(names)")
        XCTAssertEqual(try csvRows(filteredFolder), try csvRows(defaultFolder) - 1)
    }

    /// Phase 2.11 lane A67 M2. The command the row records, parsed with the real command type and
    /// run, writes the order the app wrote for the same filtered view, and the app's provenance
    /// names that command.
    func testTheFilteredViewCommandWritesTheOrderTheAppWrote() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
        let primers = snapshot.designReview.filter { $0.presentation == .schemeReference }.flatMap(\.primers)
        let settings = PrimerAnalysisDisplaySettings(hiddenPrimerIDs: [try XCTUnwrap(primers.first).id], showReverse: false)
        let selection = try PrimerOrderExportService.captureSelection(snapshot: snapshot, scope: .displayed, settings: settings)
        let draft = PrimerOrderDraft(
            selection: selection, oligos: try PrimerOrderExportService.prepare(snapshot: snapshot, selection: selection),
            defaultName: "filtered view order")
        let metadata = PrimerOrderMetadata(name: "Filtered order", requestedBy: "Bench")

        let guiDestination = fixture.root.appendingPathComponent("GUI order")
        let guiArgv = PrimerOrderExport.primerOrderExportProvenanceArgv(
            draft: draft, metadata: metadata, destinationURL: guiDestination)
        let guiOutput = try await PrimerOrderExportService().export(
            selection: selection, metadata: metadata, destinationURL: guiDestination, invocationArgv: guiArgv)
        let guiRow = MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: guiDestination)
        let gui = try PrimerOrderExportService.loadSnapshot(from: guiOutput)
        XCTAssertEqual(gui.provenance.argv, [CLICommandIdentity.executableName] + (try RecordedCLICommand.arguments(of: guiRow)))

        let cliDestination = fixture.root.appendingPathComponent("CLI order")
        let cliRow = MainSplitViewController.primerOrderExportCLICommand(
            draft: draft, metadata: metadata, destinationURL: cliDestination)
        let command = try RecordedCLICommand.parse(cliRow, as: PrimerAnalysisExportOrderCommand.self)
        try await command.run()
        let cli = try PrimerOrderExportService.loadSnapshot(from: cliDestination)

        XCTAssertEqual(cli.document.oligos, gui.document.oligos)
        XCTAssertEqual(cli.document.metadata, gui.document.metadata)
        XCTAssertEqual(cli.provenance.workflowName, gui.provenance.workflowName)
        XCTAssertEqual(try csvRows(cliDestination), try csvRows(guiDestination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cliDestination.path).sorted(),
                       try FileManager.default.contentsOfDirectory(atPath: guiDestination.path).sorted())
        XCTAssertLessThan(cli.document.oligos.count, primers.count, "the hidden primer and the reverse primers are not ordered")
    }

    // MARK: - Helpers

    private func export(_ selection: PrimerOrderSelection, to destination: URL) async throws -> URL {
        try await PrimerOrderExportService().export(
            selection: selection, metadata: PrimerOrderMetadata(name: "Pin order"),
            destinationURL: destination, invocationArgv: ["pin"])
    }

    private func csvRows(_ folder: URL) throws -> Int {
        try String(contentsOf: folder.appendingPathComponent("ordering.csv"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).count
    }

    /// Two PrimalScheme results with three primers each, the fixture PrimerOrderExportServiceTests writes.
    private func makeFixture() throws -> (root: URL, bundle: URL) {
        let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let inputID = UUID()
        var payloads = ["inputs/source.fasta": ">reference\nAACCGGTTAACC\n"]
        var results: [PrimerAnalysisResult] = []
        for index in 1...2 {
            let prefix = "native\(index)/"
            payloads[prefix + "reference.fasta"] = ">reference\nAACCGGTTAACC\n"
            payloads[prefix + "primer.bed"] = "reference\t2\t4\tfixture_1_LEFT_0\t1\t+\tCC\nreference\t2\t4\tfixture_1_LEFT_1\t1\t+\tCR\nreference\t8\t10\tfixture_1_RIGHT_0\t1\t-\tTT\n"
            payloads[prefix + "amplicon.bed"] = "reference\t2\t10\tfixture_1\t1\n"
            results.append(.init(id: UUID(), label: "MHC scheme \(index)", inputIDs: [inputID],
                artifactPaths: payloads.keys.filter { $0.hasPrefix(prefix) }.sorted()))
        }
        let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
            let source = root.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: source)
            return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path,
                role: path.hasPrefix("inputs/") ? "input" : "nativeOutput", format: path.hasSuffix(".bed") ? "bed" : "fasta")
        }
        let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .independent,
            inputs: [.init(id: inputID, artifactPaths: ["inputs/source.fasta"])], results: results, artifacts: artifacts,
            destinationURL: root.appendingPathComponent("source.lungfishprimeranalysis"),
            invocation: .init(argv: ["order-view-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        return (root, bundle.url)
    }
}
