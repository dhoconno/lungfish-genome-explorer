// BundleExportGFF3CommandTests.swift - lungfish-cli bundle export-gff3
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, ARCH ruling on 12.39 R2. The leaf takes a bundle or a selection file, exactly one, writes
// the GFF3 the app wrote for the same annotations, names only the files it read, and parses the arguments the app's
// begin helper builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class BundleExportGFF3CommandTests: XCTestCase {
    private var folder: URL!
    private var bundle: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleExportGFF3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bundle = try AnnotationGFF3ExportStreamCapture.makeBundle(in: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func command(_ arguments: [String]) throws -> BundleExportGFF3Subcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? BundleExportGFF3Subcommand)
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private static func builderBytes(_ annotations: [SequenceAnnotation], in folder: URL) async throws -> Data {
        let url = folder.appendingPathComponent("builder-\(UUID().uuidString).gff3")
        try await GFF3Writer.write(annotations, to: url, source: "Lungfish")
        return try Data(contentsOf: url)
    }

    func testBundleFormWritesTheBuilderBytesAndNamesTheFilesItRead() async throws {
        let output = folder.appendingPathComponent("fixture.gff3")
        let arguments = ["bundle", "export-gff3", bundle.path, "-o", output.path]
        _ = try await command(arguments).export()

        // A database row exports its stored ID, or `lungfish-row-<rowID>` with none (lane 13.20 M2), so the leaf's file
        // and a second load of the bundle through the builder are the same bytes.
        let loaded = try AnnotationGFF3Export.loadBundleAnnotations(bundleURL: bundle)
        let expected = try await Self.builderBytes(loaded.annotations, in: folder)
        XCTAssertEqual(try Data(contentsOf: output), expected, "the leaf writes the builder's bytes")
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.toolName, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish bundle export-gff3")
        XCTAssertEqual(envelope.argv, ["lungfish-cli", "bundle", "export-gff3", bundle.standardizedFileURL.path, "--output", output.path])
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["manifest.json", "genes.db"])
        XCTAssertTrue(inputs.allSatisfy { $0.checksumSHA256 != nil })
        XCTAssertEqual(envelope.options.resolvedDefaults["annotationCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["outputPath"])
        XCTAssertEqual(envelope.options.defaults.keys.sorted(), ["featureSource", "outputFormat"])
    }

    func testSelectionFormWritesTheDocumentAnnotationsAndNamesOnlyTheSelection() async throws {
        let output = folder.appendingPathComponent("document.gff3")
        let annotations = [
            SequenceAnnotation(type: .gene, name: "unsaved; edit", chromosome: "chr2", start: 3, end: 30),
            SequenceAnnotation(type: .cds, name: "cds-b", chromosome: "chr2", start: 5, end: 25),
        ]
        let selection = try ViewerExportSelection(documentAnnotations: AnnotationExportDocumentSelection(
            sourceName: "Edited document", sourcePath: "/tmp/edited.gb", annotations: annotations
        )).write(besideOutput: output)
        _ = try await command(["bundle", "export-gff3", "--selection", selection.path, "-o", output.path]).export()

        let expected = try await Self.builderBytes(annotations, in: folder)
        XCTAssertEqual(try Data(contentsOf: output), expected)
        let inputs = try Self.envelope(of: output).files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map(\.path), [selection.standardizedFileURL.path])
    }

    func testRefusesBothOrNeitherSourceAtParse() {
        let output = folder.appendingPathComponent("out.gff3").path
        XCTAssertThrowsError(try command(["bundle", "export-gff3", bundle.path, "--selection", "/tmp/s.json", "-o", output]))
        XCTAssertThrowsError(try command(["bundle", "export-gff3", "-o", output]))
        XCTAssertThrowsError(try command(["bundle", "export-gff3", bundle.path, "--tab", "variants", "-o", output]))
    }

    func testRefusesBeforeWriting() async throws {
        let exists = folder.appendingPathComponent("exists.gff3")
        try Data("keep".utf8).write(to: exists)
        try await assertRefused([bundle.path, "-o", exists.path], output: exists, keeps: "keep")
        try await assertRefused([bundle.path, "-o", bundle.appendingPathComponent("manifest.json").path, "--force"],
                                output: nil)
        let missing = folder.appendingPathComponent("missing.gff3")
        try await assertRefused([folder.appendingPathComponent("none.lungfishref").path, "-o", missing.path], output: missing)
        try await assertRefused(["--selection", folder.appendingPathComponent("none.json").path, "-o", missing.path], output: missing)
        let empty = try ViewerExportSelection(identities: ["a"]).write(besideOutput: missing)
        try await assertRefused(["--selection", empty.path, "-o", missing.path], output: missing)
    }

    private func assertRefused(_ extra: [String], output: URL?, keeps: String? = nil, line: UInt = #line) async throws {
        do {
            _ = try await command(["bundle", "export-gff3"] + extra).export()
            XCTFail("expected a refusal", line: line)
        } catch {
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)", line: line)
        }
        guard let output else { return }
        if let keeps {
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), keeps, line: line)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), line: line)
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// canonical argv is the executable name and the same array, for both forms.
    func testBundleExportGFF3LeafParsesTheGUIArguments() throws {
        let output = folder.appendingPathComponent("gui, out.gff3")
        for invocation in [
            AnnotationGFF3Export.invocation(bundleURL: bundle, outputURL: output, force: true),
            AnnotationGFF3Export.invocation(selectionURL: folder.appendingPathComponent("s.json"), outputURL: output, force: false),
        ] {
            let arguments = invocation.arguments()
            let leaf = try command(arguments)
            XCTAssertEqual(leaf.invocation(), invocation)
            XCTAssertEqual(leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
            XCTAssertEqual(Array(arguments.prefix(2)), AnnotationGFF3Export.commandPath)
        }
        XCTAssertEqual(BundleExportGFF3Subcommand.configuration.commandName, AnnotationGFF3Export.commandPath.last)
    }
}
