// ViewerViewControllerRunMSAInPlaceAnnotationActionParseTests.swift - the in-place MSA annotation actions record commands the CLI parses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.20 (QR-a). `ViewerViewController.runMSAInPlaceAnnotationAction` (ViewerViewController.swift) is
// private. Its two callers, `addMSAAnnotationViaCLI` and `projectMSAAnnotationViaCLI`, build the arguments and hand
// them to it, and it begins the Operations row and runs the command. Each test calls a caller on a real viewer
// against a stand-in `lungfish-cli` (BeginSiteCLIStandIn), reads the command off the row the private method began,
// parses it with the real `msa annotate add` or `msa annotate project` leaf, and compares the parsed values with the
// request.

import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class ViewerViewControllerRunMSAInPlaceAnnotationActionParseTests: XCTestCase {
    private var root: URL!
    private var standIn: BeginSiteCLIStandIn!

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "viewer-msa-annotation-action")
        standIn = BeginSiteCLIStandIn(root: root)
    }

    override func tearDown() async throws {
        standIn.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// An alignment bundle folder inside a project folder of the temporary root.
    private func makeBundleFolder() throws -> URL {
        let bundle = root.appendingPathComponent(
            "Project.lungfish/Multiple Sequence Alignments/Spike alignment.lungfishmsa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    /// Checks what every in-place annotation row shares and returns the row.
    private func requireRow(
        _ capture: BeginSiteCLIStandIn.Capture,
        title: String,
        bundle: URL
    ) throws -> OperationCenter.Item {
        XCTAssertEqual(capture.rows.count, 1, "one annotation action begins one row")
        let row = try XCTUnwrap(capture.rows.first, "the annotation action began no row")
        XCTAssertEqual(row.title, title)
        XCTAssertEqual(row.operationType, .multipleSequenceAlignmentAction)
        XCTAssertEqual(row.targetBundleURL?.standardizedFileURL, bundle.standardizedFileURL)
        XCTAssertEqual(
            capture.launchedArguments,
            try RecordedCLICommand.arguments(of: row.cliCommand),
            "the runner launched the arguments the row records"
        )
        return row
    }

    func testAddingAnAnnotationRecordsAnMSAAnnotateAddTheCLIParses() async throws {
        let bundle = try makeBundleFolder()
        let request = MultipleSequenceAlignmentAnnotationAddRequest(
            bundleURL: bundle,
            row: "Spike S1",
            columns: "10-40,55",
            name: "RBD core motif",
            type: "motif",
            strand: "+",
            note: "Binds the ACE2 receptor, see Lan 2020",
            qualifiers: ["gene=S", "product=spike glycoprotein"],
            displayName: "RBD core motif"
        )
        let viewer = ViewerViewController()
        let capture = try await standIn.capture {
            viewer.addMSAAnnotationViaCLI(request, refreshing: nil)
        }
        let row = try requireRow(capture, title: "Add MSA Annotation", bundle: bundle)
        let parsed = try RecordedCLICommand.parse(row.cliCommand, as: MSACommand.AddSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, bundle.path)
        XCTAssertEqual(parsed.row, request.row)
        XCTAssertEqual(parsed.columns, request.columns)
        XCTAssertEqual(parsed.name, request.name)
        XCTAssertEqual(parsed.type, request.type)
        XCTAssertEqual(parsed.strand, request.strand)
        XCTAssertEqual(parsed.note, request.note)
        XCTAssertEqual(parsed.qualifierOptions, request.qualifiers)
    }

    func testAddingAnAnnotationWithoutANoteOrQualifiersSendsNeither() async throws {
        let bundle = try makeBundleFolder()
        let request = MultipleSequenceAlignmentAnnotationAddRequest(
            bundleURL: bundle,
            row: "r3",
            columns: "7",
            name: "Single column",
            type: "motif",
            strand: ".",
            note: "   ",
            qualifiers: [],
            displayName: "Single column"
        )
        let viewer = ViewerViewController()
        let capture = try await standIn.capture {
            viewer.addMSAAnnotationViaCLI(request, refreshing: nil)
        }
        let row = try requireRow(capture, title: "Add MSA Annotation", bundle: bundle)
        let parsed = try RecordedCLICommand.parse(row.cliCommand, as: MSACommand.AddSubcommand.self)
        XCTAssertEqual(parsed.row, "r3")
        XCTAssertEqual(parsed.columns, "7")
        XCTAssertEqual(parsed.strand, ".")
        XCTAssertNil(parsed.note, "a blank note is not sent")
        XCTAssertEqual(parsed.qualifierOptions, [])
    }

    func testProjectingAnAnnotationRecordsAnMSAAnnotateProjectTheCLIParses() async throws {
        let bundle = try makeBundleFolder()
        let request = MultipleSequenceAlignmentAnnotationProjectionRequest(
            bundleURL: bundle,
            sourceAnnotationID: "annotation-1",
            targetRows: "r2,r3,Spike S4",
            conflictPolicy: "append",
            displayName: "RBD core motif"
        )
        let viewer = ViewerViewController()
        let capture = try await standIn.capture {
            viewer.projectMSAAnnotationViaCLI(request, refreshing: nil)
        }
        let row = try requireRow(capture, title: "Apply MSA Annotation", bundle: bundle)
        let parsed = try RecordedCLICommand.parse(row.cliCommand, as: MSACommand.ProjectSubcommand.self)
        XCTAssertEqual(parsed.bundlePath, bundle.path)
        XCTAssertEqual(parsed.sourceAnnotation, request.sourceAnnotationID)
        XCTAssertEqual(parsed.targetRows, request.targetRows)
        XCTAssertEqual(parsed.conflictPolicy, request.conflictPolicy)
    }
}
