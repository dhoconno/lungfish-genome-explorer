// VariantsExportCommandTests.swift - lungfish-cli variants export bookmarked and variants export sample-template
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 c2, ARCH ruling X-1 rows B6 and B11, X-3 and BIO 5 and 6. Each leaf writes the bytes the
// drawer wrote, names only the variant databases it read, refuses before it writes, and parses the arguments the
// drawer's begin helper builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class VariantsExportCommandTests: XCTestCase {
    private var folder: URL!
    private var fixture: VariantEditFixture!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantsExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture = try VariantEditFixture.make(in: folder, withTrackManifest: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func parse<Leaf: ParsableCommand>(_ arguments: [String], as _: Leaf.Type) throws -> Leaf {
        try XCTUnwrap(try LungfishCLI.parseAsRoot(arguments) as? Leaf)
    }

    private func bookmarkFirstTwo() throws {
        let database = try VariantDatabase(url: fixture.databaseURL, readWrite: true)
        for id in try fixture.variantIDs().prefix(2) {
            XCTAssertTrue(database.toggleBookmark(variantId: id))
        }
    }

    private static func envelope(of output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
    }

    // MARK: variants export bookmarked

    func testBookmarkedLeafWritesTheStoredBookmarksAndNamesTheDatabase() throws {
        try bookmarkFirstTwo()
        let output = folder.appendingPathComponent("bookmarks.tsv")
        let arguments = ["variants", "export", "bookmarked", fixture.databaseURL.path, "--output", output.path]
        _ = try parse(arguments, as: VariantsCommand.ExportBookmarkedSubcommand.self).export()
        let lines = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertEqual(lines.first, "ID\tType\tChrom\tPos\tRef\tAlt\tQuality\tFilter")
        XCTAssertTrue(lines.count == 4 && lines[1].hasSuffix("\tSNP\tchr1\t100\tA\tG\t50.0\tPASS"), "\(lines)")
        XCTAssertTrue(lines.count == 4 && lines[2].hasSuffix("\tSNP\tchr1\t200\tC\tT\t50.0\tPASS"), "\(lines)")
        XCTAssertEqual(lines.last, "")
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish variants export bookmarked")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let inputs = envelope.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map(\.path), [fixture.databaseURL.standardizedFileURL.path])
        XCTAssertNotNil(inputs.first?.checksumSHA256)
        XCTAssertEqual(envelope.options.resolvedDefaults["variantCount"]?.integerValue, 2)
    }

    func testBookmarkedLeafRefusesNoBookmarksAMissingDatabaseAndAnExistingOutput() throws {
        let output = folder.appendingPathComponent("refused.tsv")
        for database in [fixture.databaseURL.path, folder.appendingPathComponent("missing.db").path] {
            XCTAssertThrowsError(try parse(
                ["variants", "export", "bookmarked", database, "-o", output.path], as: VariantsCommand.ExportBookmarkedSubcommand.self
            ).export()) { XCTAssertTrue($0 is ViewerExportRefusal, "\($0)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        try bookmarkFirstTwo()
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try parse(
            ["variants", "export", "bookmarked", fixture.databaseURL.path, "-o", output.path], as: VariantsCommand.ExportBookmarkedSubcommand.self
        ).export()) { XCTAssertTrue($0 is ViewerExportRefusal, "\($0)") }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
    }

    func testVariantsBookmarkedLeafParsesTheGUIArguments() throws {
        let second = folder.appendingPathComponent("second.db")
        try FileManager.default.copyItem(at: fixture.databaseURL, to: second)
        let invocation = BookmarkedVariantExport.invocation(
            databaseURLs: [fixture.databaseURL, second],
            outputURL: folder.appendingPathComponent("gui, bookmarks.tsv"),
            force: true
        )
        let arguments = invocation.arguments()
        let leaf = try parse(arguments, as: VariantsCommand.ExportBookmarkedSubcommand.self)
        XCTAssertEqual(leaf.invocation(), invocation)
        XCTAssertEqual(leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), BookmarkedVariantExport.commandPath)
        XCTAssertEqual(VariantsCommand.ExportBookmarkedSubcommand.configuration.commandName, BookmarkedVariantExport.commandPath.last)
    }

    func testVariantsBookmarkedLeafRefusesAnOptionItDoesNotTake() {
        let base = ["variants", "export", "bookmarked", fixture.databaseURL.path, "-o", folder.appendingPathComponent("x.tsv").path]
        XCTAssertThrowsError(try LungfishCLI.parseAsRoot(base + ["--output-format", "csv"]))
        XCTAssertThrowsError(try LungfishCLI.parseAsRoot(base + ["--selection", "/tmp/selection.json"]))
    }

    // MARK: variants export sample-template

    func testSampleTemplateLeafWritesTheDrawerRowsAndNamesTheDatabase() throws {
        let output = folder.appendingPathComponent("template.csv")
        let arguments = [
            "variants", "export", "sample-template", fixture.bundleURL.path,
            "--metadata-column", "cohort", "--metadata-column", "collection_date", "--output-format", "csv", "--output", output.path,
        ]
        _ = try parse(arguments, as: VariantsCommand.ExportSampleTemplateSubcommand.self).export()
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), """
        sample_name,source_file,cohort,collection_date
        SAMPLE_A,reference.vcf,,
        SAMPLE_B,reference.vcf,,

        """)
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.workflowName, "lungfish variants export sample-template")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        XCTAssertEqual(envelope.files.filter { $0.role == .input }.map(\.path), [fixture.databaseURL.standardizedFileURL.path])
        XCTAssertEqual(envelope.options.resolvedDefaults["sampleCount"]?.integerValue, 2)
    }

    func testSampleTemplateLeafRefusesABundleWithNoSamplesBeforeWriting() throws {
        let empty = try VariantEditFixture.make(in: folder, named: "empty", withTrackManifest: false)
        let output = folder.appendingPathComponent("empty.tsv")
        XCTAssertThrowsError(try parse(
            ["variants", "export", "sample-template", empty.bundleURL.path, "--output-format", "tsv", "-o", output.path],
            as: VariantsCommand.ExportSampleTemplateSubcommand.self
        ).export()) { XCTAssertTrue($0 is ViewerExportRefusal, "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testVariantsSampleTemplateLeafParsesTheGUIArguments() throws {
        let invocation = VariantSampleTemplateExport.invocation(
            bundleURL: fixture.bundleURL,
            metadataColumns: ["cohort", "added in view"],
            format: .tsv,
            outputURL: folder.appendingPathComponent("gui template.tsv"),
            force: false
        )
        let arguments = invocation.arguments()
        let leaf = try parse(arguments, as: VariantsCommand.ExportSampleTemplateSubcommand.self)
        XCTAssertEqual(try leaf.invocation(), invocation)
        XCTAssertEqual(try leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), VariantSampleTemplateExport.commandPath)
        XCTAssertEqual(
            VariantsCommand.ExportSampleTemplateSubcommand.configuration.commandName, VariantSampleTemplateExport.commandPath.last
        )
    }

    func testVariantsSampleTemplateLeafRefusesAnOptionItDoesNotTake() {
        let base = [
            "variants", "export", "sample-template", fixture.bundleURL.path, "--output-format", "tsv",
            "-o", folder.appendingPathComponent("x.tsv").path,
        ]
        XCTAssertThrowsError(try LungfishCLI.parseAsRoot(base + ["--sample", "SAMPLE_A"]))
        XCTAssertThrowsError(try LungfishCLI.parseAsRoot(base + ["--sort", "sample_name:ascending"]))
    }
}
