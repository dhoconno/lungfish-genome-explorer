// ReferenceImportLeafExitReplayTests.swift - The app writes no byte after import fasta exits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48 M3, plan decision C5 and ruling A48 F2 pin P7. Both reference import sites
// run `import fasta` on `CLIBundleBuildRunner` through `AppDelegate.runReferenceImport`, which ends
// the row once the command exited. The helper route attached the annotations, wrote the extraction
// record and merged the source's record in the app after the helper exited. Now the command does
// all of it, so the project's file list and the digest of every file, each record included, read
// when the command exits equal those read when the row completes.
//
// It launches the built lungfish-cli, which runs the managed bgzip and samtools faidx, so its name
// ends in ReplayTests, which sends it to the integration tier, and it skips without the tools
// unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ReferenceImportLeafExitReplayTests: XCTestCase {
    private var root: URL!
    private var cli: URL!

    override func setUp() async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        root = try TestTempDirectory.make(prefix: "reference-import-leaf-exit").resolvingSymlinksInPath()
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    func testReferenceImportWritesNoByteAfterTheLeafExits() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let records = [">seqA first\nACGTACGTAC\n", ">seqB\nGGCCAATTGGCC\n"]

        // The viewer's Import Center form, a staged selection bundle whose record the run merges.
        let stagedBundle = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: records, suggestedName: "Selection", projectURL: project,
            makeTemporaryRoot: { staging.appendingPathComponent("import-center", isDirectory: true) }
        )
        let importCenter = AppDelegate.referenceImportArguments(
            sourceURL: stagedBundle.appendingPathComponent("selection.fasta"), projectURL: project,
            preferredBundleName: "Plain Selection", rehydrateSourceProvenance: true
        )

        // The annotated form, a staged FASTA, BED and selection.
        let fasta = staging.appendingPathComponent("selection.fasta")
        try records.joined().write(to: fasta, atomically: true, encoding: .utf8)
        let bed = staging.appendingPathComponent("selected-annotations.bed")
        try "seqA\t1\t6\tgeneA\t0\t+\t1\t6\t0,0,0\t1\t5,\t0,\tgene\t\n".write(to: bed, atomically: true, encoding: .utf8)
        let selection = staging.appendingPathComponent("selected-annotations.json")
        try JSONEncoder().encode(MSAExtractionAnnotationProvenance.annotationSelectionValue([
            "seqA": [SequenceAnnotation(
                type: .gene, name: "geneA", chromosome: "seqA", intervals: [AnnotationInterval(start: 1, end: 6)],
                strand: .forward, note: "kept note"
            )],
        ])).write(to: selection)
        // The viewer names the bundles the selection came from, which are folders.
        let export = staging.appendingPathComponent("Source.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try #"{"schemaVersion":1}"#.write(to: export.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let annotated = AppDelegate.referenceImportArguments(
            sourceURL: fasta, projectURL: project, preferredBundleName: "Annotated Selection",
            provenanceInputFiles: [export], annotationsURL: bed, annotationSelectionURL: selection
        )

        let shapes: [(name: String, arguments: [String], detail: (URL) -> String, written: String)] = [
            ("Import Center", importCenter, { "Imported \($0.lastPathComponent)" }, ProvenanceWriter.provenanceFilename),
            ("annotated", annotated, ViewerViewController.annotatedReferenceImportDetail(bundleURL:),
             "annotations/msa-extraction-annotations-provenance.json"),
        ]
        let runner = CLIBundleBuildRunner(cliURLOverride: cli)
        for shape in shapes {
            let reporter = RecordingOperationReporter()
            guard case .started(let operationID) = reporter.begin(
                title: "Reference Import", detail: "Importing...", operationType: .bundleBuild,
                cliCommand: nil, routeContext: nil
            ) else { return XCTFail("\(shape.name): the row did not start") }
            var atExit: [String: String] = [:]
            let outcome = await AppDelegate.runReferenceImport(
                arguments: shape.arguments, operationID: operationID, reporter: reporter, detail: shape.detail,
                run: { arguments, id in
                    let result = try await runner.run(arguments: arguments, operationID: id)
                    atExit = Self.snapshot(of: project)
                    return result
                }
            )
            let bundle = try XCTUnwrap(outcome.bundleURL, "\(shape.name): \(outcome.error.map { "\($0)" } ?? "no row end")")
            let bundlePath = String(bundle.path.dropFirst(project.path.count))
            XCTAssertNotNil(atExit[bundlePath + "/" + shape.written], "\(shape.name): the command wrote its record before it exited")
            XCTAssertEqual(Self.snapshot(of: project), atExit, "\(shape.name): the app wrote after the command exited")
        }
    }

    /// Each file and folder under `folder`, by its path inside it, with the SHA-256 of each file.
    private static func snapshot(of folder: URL) -> [String: String] {
        var entries: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(folder.path.count))
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            entries[path] = isFolder ? "folder" : (ProvenanceRecorder.sha256(of: url) ?? "unreadable")
        }
        return entries
    }
}
