// BundleExportAnnotationTableCommandTests.swift - lungfish-cli bundle export-annotation-table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 and R3. The leaf reads the rows the selection names from the bundle's
// databases, writes them with the drawer's builder in the format asked for, names the selection, the manifest and
// the database it read with their digests, and refuses before it writes anything when the selection names a row the
// bundle does not hold.

import XCTest
import ArgumentParser
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishWorkflow

final class BundleExportAnnotationTableCommandTests: XCTestCase {
    private var folder: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleExportAnnotationTable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bundle = try AnnotationGFF3ExportStreamCapture.makeBundle(in: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func command(_ arguments: [String]) throws -> BundleExportAnnotationTableSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(["bundle", "export-annotation-table"] + arguments)
        return try XCTUnwrap(parsed as? BundleExportAnnotationTableSubcommand)
    }

    private func writeSelection(_ selection: ViewerExportSelection, beside output: URL) throws -> URL {
        try selection.write(besideOutput: output)
    }

    /// The drawer's bytes for the fixture's one gene, built from the row as the drawer holds it.
    private static func drawerBytes(format: ScientificTableFormat, in folder: URL) throws -> Data {
        let row = AnnotationSearchResult(
            name: "gene-a", chromosome: "chr1", start: 10, end: 20, trackId: "genes", trackName: "Genes",
            type: "gene", strand: "+", attributes: ["tag": "value"], annotationRowId: 1
        )
        let snapshot = AnnotationTableExportSnapshot.captureAnnotations(
            [row], columns: AnnotationTableExportStreamCapture.annotationColumns, scope: .allMatching,
            sourceURLs: [], queryDescription: ["text": "", "sort": "database-default:ascending"]
        )
        let url = folder.appendingPathComponent("drawer-\(UUID().uuidString).\(format.rawValue)")
        _ = try ScientificTableWriter.writeWithReport(snapshot.table, format: format, to: url, shouldCancel: { false })
        return try Data(contentsOf: url)
    }

    func testAnnotationsTabWritesTheDrawerBytesAndNamesTheFilesItRead() async throws {
        for format in [ScientificTableFormat.tsv, .csv, .json] {
            let output = folder.appendingPathComponent("genes.\(format.rawValue)")
            let selection = try writeSelection(AnnotationTableExportStreamCapture.annotationSelection(), beside: output)
            let arguments = [
                bundle.path, "--tab", "annotations", "--output-format", format.rawValue,
                "--selection", selection.path, "-o", output.path,
            ]
            _ = try await command(arguments).export()

            XCTAssertEqual(try Data(contentsOf: output), try Self.drawerBytes(format: format, in: folder), "\(format)")
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
            XCTAssertEqual(envelope.toolName, "lungfish-cli")
            XCTAssertEqual(envelope.tool.kind, "cli")
            XCTAssertEqual(envelope.workflowName, "lungfish bundle export-annotation-table")
            XCTAssertEqual(envelope.argv, [
                "lungfish-cli", "bundle", "export-annotation-table", bundle.standardizedFileURL.path,
                "--tab", "annotations", "--output-format", format.rawValue,
                "--selection", selection.standardizedFileURL.path, "--output", output.path,
            ])
            XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
            let inputs = envelope.files.filter { $0.role == .input }
            XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["selection.json", "manifest.json", "genes.db"])
            XCTAssertTrue(inputs.allSatisfy { $0.checksumSHA256 != nil })
            XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputFormat", "outputPath", "tab"])
            XCTAssertEqual(envelope.options.defaults.keys.sorted(), AnnotationTableExportSnapshot.recordDefaults.keys.sorted())
            XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 1)
            XCTAssertEqual(envelope.options.resolvedDefaults["rowIdentities"], .array([.string("genes:1")]))
        }
    }

    func testRefusesBeforeWriting() async throws {
        let output = folder.appendingPathComponent("refused.tsv")
        func assertRefused(_ selection: ViewerExportSelection?, bundle: URL? = nil, line: UInt = #line) async throws {
            let selectionURL = try selection.map { try writeSelection($0, beside: output) }
                ?? folder.appendingPathComponent("none.json")
            do {
                _ = try await command([
                    (bundle ?? self.bundle).path, "--tab", "annotations", "--output-format", "tsv",
                    "--selection", selectionURL.path, "-o", output.path,
                ]).export()
                XCTFail("expected a refusal", line: line)
            } catch {
                XCTAssertTrue(error is ViewerExportRefusal, "\(error)", line: line)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), line: line)
        }
        try await assertRefused(nil)
        try await assertRefused(ViewerExportSelection(identities: ["genes:1"]))
        try await assertRefused(AnnotationTableExportStreamCapture.annotationSelection(identities: ["other:1"]))
        try await assertRefused(AnnotationTableExportStreamCapture.annotationSelection(identities: ["genes:99"]))
        try await assertRefused(AnnotationTableExportStreamCapture.annotationSelection(identities: ["genes:1", "genes:1"]))
        try await assertRefused(
            AnnotationTableExportStreamCapture.annotationSelection(),
            bundle: folder.appendingPathComponent("none.lungfishref", isDirectory: true)
        )
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// invocation is the one the helper built, so the row and the record name one command.
    func testTheGUIArgumentsParseIntoTheLeaf() throws {
        let invocation = AnnotationTableExport.invocation(
            bundleURL: URL(fileURLWithPath: "/tmp/lane 12.39/Reference, one.lungfishref", isDirectory: true),
            tab: .variants,
            format: .xlsx,
            selectionURL: URL(fileURLWithPath: "/tmp/lane 12.39/.lungfish-export-inputs/A/selection.json"),
            outputURL: URL(fileURLWithPath: "/tmp/lane 12.39/variants, all.xlsx"),
            force: true
        )
        let parsed = try LungfishCLI.parseAsRoot(invocation.arguments())
        let command = try XCTUnwrap(parsed as? BundleExportAnnotationTableSubcommand)
        XCTAssertEqual(command.invocation(), invocation)
        XCTAssertEqual(BundleExportAnnotationTableSubcommand.configuration.commandName, AnnotationTableExport.commandPath.last)
        XCTAssertEqual(AnnotationTableExport.Tab.allCases.map(\.rawValue), ["annotations", "variants", "genotypes", "samples"])
        XCTAssertEqual(ScientificTableFormat.allCases.map(\.rawValue).sorted(), ["csv", "json", "tsv", "xlsx"])
    }
}
