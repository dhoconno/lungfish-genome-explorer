// GenotypeExportManualDefinitionsCommandTests.swift - lungfish-cli genotype export-manual-definitions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Phase 2.12 lane 12.35 M2, ARCH ruling 1.1 row A14 and 1.3. The leaf reads the assignments from the selection file
/// the app wrote, applies the shared index and names that one file as its input.
final class GenotypeExportManualDefinitionsCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "genotype-export-manual-definitions")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private static let assignments = [
        ManualHaplotypeAssignment(sample: "animal-1", locus: "MHC-A", slot: .h1, label: "Mamu-A1*001/002",
                                  colorTokenIndex: 1, diagnosticAlleles: ["A1_001"], notes: "kept"),
        ManualHaplotypeAssignment(sample: "animal-2", locus: "MHC-B", slot: .h2, label: "Mamu-B*008",
                                  colorTokenIndex: 3, diagnosticAlleles: ["B_008", "B_008b"], notes: "",
                                  assignmentID: "id-2", updatedAt: "2026-10-01T00:00:00Z", author: "tester"),
    ]

    private func makeInputs() throws -> (bundle: URL, selection: URL, output: URL) {
        let bundle = root.appendingPathComponent("manual.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("manual-haplotype-definitions.json")
        let selection = try GenotypeManualDefinitionsExport.selection(assignments: Self.assignments)
            .write(besideOutput: output)
        return (bundle, selection, output)
    }

    func testTheSelectionRoundTripsTheAssignmentsInOrder() throws {
        let selection = try GenotypeManualDefinitionsExport.selection(assignments: Self.assignments)
        let decoded = try JSONDecoder().decode(ViewerExportSelection.self, from: selection.encoded())
        XCTAssertEqual(decoded.identities, ["1", "2"])
        XCTAssertEqual(try GenotypeManualDefinitionsExport.assignments(from: decoded), Self.assignments)
    }

    func testGenotypeManualDefinitionsLeafParsesTheGUIArguments() throws {
        let inputs = try makeInputs()
        let invocation = GenotypeManualDefinitionsExport.invocation(
            bundleURL: inputs.bundle, selectionURL: inputs.selection, outputURL: inputs.output, force: true
        )
        let command = try GenotypeExportManualDefinitionsSubcommand.parse(
            Array(invocation.arguments().dropFirst(GenotypeManualDefinitionsExport.commandPath.count))
        )
        XCTAssertEqual(command.invocation(), invocation)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testGenotypeManualDefinitionsLeafRefusesAnOptionItDoesNotTake() {
        XCTAssertThrowsError(try GenotypeExportManualDefinitionsSubcommand.parse([
            "/tmp/b.lungfishgenotype", "--selection", "/tmp/s.json", "--output", "/tmp/o.json", "--sample", "animal-1",
        ]))
        XCTAssertThrowsError(try GenotypeExportManualDefinitionsSubcommand.parse([
            "/tmp/b.lungfishgenotype", "--output", "/tmp/o.json",
        ]), "the selection file is required")
    }

    func testTheLeafWritesTheCurrentAssignmentsAndNamesOnlyTheSelection() throws {
        let inputs = try makeInputs()
        let command = try GenotypeExportManualDefinitionsSubcommand.parse([
            inputs.bundle.path, "--selection", inputs.selection.path, "--output", inputs.output.path,
        ])
        let outcome = try command.export()
        XCTAssertEqual(outcome.message, "Exported 2 manual haplotype assignments to manual-haplotype-definitions.json")

        let current = GenotypeManualDefinitionsExport.currentAssignments(Self.assignments)
        XCTAssertEqual(try Data(contentsOf: inputs.output), try GenotypeManualDefinitionsExport.payload(currentAssignments: current))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: inputs.output)
        ))
        XCTAssertEqual(envelope.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish genotype export-manual-definitions")
        XCTAssertEqual(envelope.argv, command.invocation().canonicalArgv())
        XCTAssertEqual(envelope.files.filter { $0.role == .input }.map(\.path), [inputs.selection.standardizedFileURL.path])
        XCTAssertEqual(envelope.options.resolvedDefaults["assignmentCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["bundle", "output", "selection"])
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "json")
    }

    func testTheLeafRefusesAMissingBundleAMissingSelectionAndAnExistingOutput() throws {
        let inputs = try makeInputs()
        let missingBundle = try GenotypeExportManualDefinitionsSubcommand.parse([
            root.appendingPathComponent("none.lungfishgenotype").path,
            "--selection", inputs.selection.path, "--output", inputs.output.path,
        ])
        XCTAssertThrowsError(try missingBundle.export()) { XCTAssertTrue($0 is ViewerExportRefusal, "\($0)") }
        let missingSelection = try GenotypeExportManualDefinitionsSubcommand.parse([
            inputs.bundle.path, "--selection", root.appendingPathComponent("none.json").path,
            "--output", inputs.output.path,
        ])
        XCTAssertThrowsError(try missingSelection.export()) { XCTAssertTrue($0 is ViewerExportRefusal, "\($0)") }
        try Data("[]".utf8).write(to: inputs.output)
        let existing = try GenotypeExportManualDefinitionsSubcommand.parse([
            inputs.bundle.path, "--selection", inputs.selection.path, "--output", inputs.output.path,
        ])
        XCTAssertThrowsError(try existing.export()) { XCTAssertTrue($0 is ViewerExportRefusal, "\($0)") }
        XCTAssertEqual(try Data(contentsOf: inputs.output), Data("[]".utf8), "a refusal writes nothing")
    }
}
