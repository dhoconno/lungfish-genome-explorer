// ViewerViewControllerExportMSASelectionViaCLIParseTests.swift - exportMSASelectionViaCLI records a command the CLI parses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.20 (QR-a). `ViewerViewController.exportMSASelectionViaCLI` (ViewerViewController.swift) returns
// when the viewer has no window, awaits a `DefaultSavePanelPresenter` that the method creates itself, and only then
// builds its command and begins the Operations row. No test can answer that save panel, so the method cannot be driven
// to its begin without a new seam in Sources. The seam a later lane needs is a stored `SavePanelPresenting` on the
// viewer, as `alignmentExtractionSavePanelPresenter` is for the extraction. Until then these tests do two things.
// They run the real method with no window and require that it begins nothing, and they build the command the way the
// method does (`CLIMSAActionCommandBuilder.buildSelectionExportArguments`, then `displayCommand`) for the destination a
// save panel would return, and parse it with the real `msa export` or `msa extract` leaf.

import XCTest
import LungfishKit
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class ViewerViewControllerExportMSASelectionViaCLIParseTests: XCTestCase {
    private let bundle = URL(
        fileURLWithPath: "/tmp/Project.lungfish/Multiple Sequence Alignments/Spike alignment.lungfishmsa",
        isDirectory: true
    )

    private func request(
        outputKind: String,
        rows: String? = "r2,r5",
        columns: String? = "10-40,55"
    ) -> MultipleSequenceAlignmentSelectionExportRequest {
        MultipleSequenceAlignmentSelectionExportRequest(
            bundleURL: bundle,
            outputKind: outputKind,
            rows: rows,
            columns: columns,
            suggestedName: "Spike selection",
            displayName: "Spike selection"
        )
    }

    /// The command `exportMSASelectionViaCLI` records for `request` once the save panel returned `destination`.
    private func recordedCommand(
        for request: MultipleSequenceAlignmentSelectionExportRequest,
        destination: URL
    ) -> String {
        let arguments = CLIMSAActionCommandBuilder.buildSelectionExportArguments(
            request: request,
            outputURL: destination
        )
        return CLIMSAActionCommandBuilder.displayCommand(arguments: arguments)
    }

    func testAViewerWithNoWindowBeginsNoRowBeforeTheSavePanelAnswers() {
        let viewer = ViewerViewController()
        let existing = Set(OperationCenter.shared.items.map(\.id))
        viewer.exportMSASelectionViaCLI(request(outputKind: "aligned-fasta"))
        let added = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        XCTAssertEqual(added.map(\.title), [], "the method begins no row until a destination exists")
    }

    func testAnAlignedFastaSelectionRecordsAnMSAExportTheCLIParses() throws {
        let destination = URL(fileURLWithPath: "/tmp/Exports/Spike selection.fasta")
        let command = recordedCommand(for: request(outputKind: "aligned-fasta"), destination: destination)
        let parsed = try RecordedCLICommand.parse(command, as: MSACommand.ExportSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, bundle.path)
        XCTAssertEqual(parsed.outputFormat, "aligned-fasta")
        XCTAssertEqual(parsed.outputPath, destination.path)
        XCTAssertEqual(parsed.rows, "r2,r5")
        XCTAssertEqual(parsed.columns, "10-40,55")
        XCTAssertTrue(parsed.force)
    }

    func testAReferenceSelectionRecordsAnMSAExtractTheCLIParses() throws {
        let destination = URL(fileURLWithPath: "/tmp/Exports/Spike selection.lungfishref", isDirectory: true)
        let command = recordedCommand(for: request(outputKind: "reference"), destination: destination)
        let parsed = try RecordedCLICommand.parse(command, as: MSACommand.ExtractSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, bundle.path)
        XCTAssertEqual(parsed.outputKind, "reference")
        XCTAssertEqual(parsed.outputPath, destination.path)
        XCTAssertEqual(parsed.name, "Spike selection")
        XCTAssertEqual(parsed.rows, "r2,r5")
        XCTAssertEqual(parsed.columns, "10-40,55")
        XCTAssertTrue(parsed.force)
    }

    func testAnMSASelectionRecordsAnMSAExtractToAnMSABundleTheCLIParses() throws {
        let destination = URL(fileURLWithPath: "/tmp/Exports/Spike subset.lungfishmsa", isDirectory: true)
        let command = recordedCommand(for: request(outputKind: "msa"), destination: destination)
        let parsed = try RecordedCLICommand.parse(command, as: MSACommand.ExtractSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, bundle.path)
        XCTAssertEqual(parsed.outputKind, "msa")
        XCTAssertEqual(parsed.outputPath, destination.path)
        XCTAssertEqual(parsed.name, "Spike subset")
        XCTAssertEqual(parsed.rows, "r2,r5")
        XCTAssertEqual(parsed.columns, "10-40,55")
        XCTAssertTrue(parsed.force)
    }

    func testASelectionWithBlankRowsAndColumnsSendsNoSubset() throws {
        let destination = URL(fileURLWithPath: "/tmp/Exports/Spike selection.fasta")
        let command = recordedCommand(
            for: request(outputKind: "aligned-fasta", rows: "  ", columns: nil),
            destination: destination
        )
        let parsed = try RecordedCLICommand.parse(command, as: MSACommand.ExportSubcommand.self)
        XCTAssertNil(parsed.rows)
        XCTAssertNil(parsed.columns)
        XCTAssertEqual(parsed.outputPath, destination.path)
    }
}
