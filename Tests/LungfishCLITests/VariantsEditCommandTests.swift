// VariantsEditCommandTests.swift - variants delete and variants import-sample-metadata
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A43 M2, plan decision C3. Each leaf calls the Workflow function the variant
// table calls, so the bundle and its records equal what the table writes (BIO 4). Each test makes
// one bundle, copies its root, runs the table's service call on one copy and the leaf in this
// process on the other, and compares the sorted rows of the variant database and the main
// provenance record with the root's path masked (`VariantEditDump`). The leaf's record names the
// command and the table's call is given the same argv, as the table's row will record it.

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class VariantsEditCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variants-edit-command")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Help and parsing

    func testVariantsHelpListsTheTwoEditLeavesAndEachHelpNamesItsOptions() {
        let group = VariantsCommand.helpMessage()
        XCTAssertTrue(group.contains("delete"))
        XCTAssertTrue(group.contains("import-sample-metadata"))
        let delete = VariantsCommand.DeleteSubcommand.helpMessage()
        XCTAssertTrue(delete.contains("--all"))
        XCTAssertTrue(delete.contains("--variant-id"))
        XCTAssertTrue(delete.contains("<track-id>:<row-id>"))
        let metadata = VariantsCommand.ImportSampleMetadataSubcommand.helpMessage()
        XCTAssertTrue(metadata.contains("--metadata-format"))
        XCTAssertTrue(metadata.contains("--format"), "the global events flag keeps its name")
    }

    func testDeleteNeedsExactlyOneOfAllAndVariantIDs() throws {
        XCTAssertNoThrow(try VariantsCommand.DeleteSubcommand.parse(["B.lungfishref", "--all"]))
        let several = try VariantsCommand.DeleteSubcommand.parse(
            ["B.lungfishref", "--variant-id=a:b:7", "--variant-id", "c:1"]
        )
        XCTAssertEqual(several.variantIDs, ["a:b:7", "c:1"])
        XCTAssertThrowsError(try VariantsCommand.DeleteSubcommand.parse(["B.lungfishref"]), "no selection")
        XCTAssertThrowsError(try VariantsCommand.DeleteSubcommand.parse(["B.lungfishref", "--all", "--variant-id=a:1"]), "both")
        XCTAssertThrowsError(try VariantsCommand.DeleteSubcommand.parse(["B.lungfishref", "--variant-id=7"]), "no track")
    }

    func testMetadataFormatMustBeCsvOrTsvAndFollowsTheExtension() throws {
        XCTAssertThrowsError(try VariantsCommand.ImportSampleMetadataSubcommand.parse(["B.lungfishref", "m.xlsx", "--metadata-format", "excel"]))
        let byName = try VariantsCommand.ImportSampleMetadataSubcommand.parse(["B.lungfishref", "m.CSV"])
        XCTAssertEqual(byName.resolvedFormat(for: URL(fileURLWithPath: "/x/m.CSV")), .csv)
        XCTAssertEqual(byName.resolvedFormat(for: URL(fileURLWithPath: "/x/m.txt")), .tsv, "any other extension reads as tsv, as the table does")
        let named = try VariantsCommand.ImportSampleMetadataSubcommand.parse(["B.lungfishref", "m.txt", "--metadata-format", "csv"])
        XCTAssertEqual(named.resolvedFormat(for: URL(fileURLWithPath: "/x/m.tsv")), .csv, "the option wins")
    }

    // MARK: - The leaf writes what the table's call writes

    func testSelectedDeletionWritesWhatTheTablesCallWrites() async throws {
        let (a, c) = try twoRoots()
        let ids = try a.variantIDs()
        let selection = [VariantEditFixture.trackID: [ids[1], ids[2]]]
        _ = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
            idsByTrack: selection, bundleURL: a.bundleURL, targets: [tableTarget(a)],
            invocationArgv: [CLICommandIdentity.executableName]
                + VariantDeletionMutationService.deleteSelectedArguments(bundleURL: a.bundleURL, idsByTrack: selection)
        )
        let leaf = try VariantsCommand.DeleteSubcommand.parse(
            [c.bundleURL.path] + ids[1...2].map { "--variant-id=\(VariantEditFixture.trackID):\($0)" } + ["--format", "json"]
        )
        let events = try await CLIEventTranscriptCoverageTests.eventLines { try await leaf.execute(emit: $0) }
        XCTAssertEqual(try Self.words(of: events), ["start: Updating stored data and provenance", "complete: Data and provenance updated"])
        try assertSameBundle(a, c)
    }

    func testDeleteAllWritesWhatTheTablesCallWrites() async throws {
        let (a, c) = try twoRoots()
        _ = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteAllVariants(
            bundleURL: a.bundleURL, targets: [tableTarget(a)],
            invocationArgv: [CLICommandIdentity.executableName] + VariantDeletionMutationService.deleteAllArguments(bundleURL: a.bundleURL)
        )
        let leaf = try VariantsCommand.DeleteSubcommand.parse([c.bundleURL.path, "--all", "--format", "json"])
        let events = try await CLIEventTranscriptCoverageTests.eventLines { try await leaf.execute(emit: $0) }
        XCTAssertEqual(try Self.words(of: events), ["start: Updating stored data and provenance", "complete: Data and provenance updated"])
        try assertSameBundle(a, c)
    }

    func testMetadataImportWritesWhatTheTablesCallWrites() async throws {
        let (a, c) = try twoRoots(withMetadata: true)
        let metadataA = a.root.appendingPathComponent("metadata.tsv")
        _ = try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
            from: metadataA, format: .tsv, bundleURL: a.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: a.databaseURL, trackName: VariantEditFixture.trackID)],
            invocationArgv: [CLICommandIdentity.executableName] + VariantSampleMetadataImportService.importMetadataArguments(
                metadataURL: metadataA, format: .tsv, bundleURL: a.bundleURL
            )
        )
        let leaf = try VariantsCommand.ImportSampleMetadataSubcommand.parse([
            c.bundleURL.path, c.root.appendingPathComponent("metadata.tsv").path, "--format", "json",
        ])
        let events = try await CLIEventTranscriptCoverageTests.eventLines { try await leaf.execute(emit: $0) }
        XCTAssertEqual(try Self.words(of: events), ["start: Updating stored data and provenance", "complete: Data and provenance updated"])
        try assertSameBundle(a, c)
    }

    func testMetadataImportNamesTheFormatItWasGiven() async throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let file = root.appendingPathComponent("samples.txt")
        try "sample_name,cohort\nSAMPLE_A,treated\nSAMPLE_B,control\n".write(to: file, atomically: true, encoding: .utf8)
        let leaf = try VariantsCommand.ImportSampleMetadataSubcommand.parse(
            [fixture.bundleURL.path, file.path, "--metadata-format", "csv", "--quiet"]
        )
        try await leaf.execute(emit: { _ in })
        let lines = try VariantEditDump.provenance(of: fixture.bundleURL, root: root).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("options.explicit.format.value = csv"))
        XCTAssertTrue(lines.contains("argv[6] = csv"), "the record's command names the format: \(lines.filter { $0.hasPrefix("argv") })")
        XCTAssertTrue(try VariantEditDump.rows(of: fixture.databaseURL).contains("treated"), "the file was read as csv")
    }

    // MARK: - A refused edit writes nothing

    func testASelectionOfATrackTheBundleLacksIsRefusedBeforeAnyWrite() async throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let before = try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL])
        let leaf = try VariantsCommand.DeleteSubcommand.parse([fixture.bundleURL.path, "--variant-id=nope:1", "--format", "json"])
        let events = try await CLIEventTranscriptCoverageTests.eventLines(expectingFailure: true) {
            try await leaf.execute(emit: $0)
        }
        let words = try Self.words(of: events)
        XCTAssertEqual(words.first, "start: Updating stored data and provenance")
        XCTAssertTrue(words.last?.hasPrefix("failed: The bundle holds no variant track 'nope'") == true, "\(words)")
        XCTAssertEqual(try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL]), before)
    }

    func testAMissingMetadataFileOrBundleIsRefusedBeforeAnyWrite() async throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let before = try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL])
        let noFile = try VariantsCommand.ImportSampleMetadataSubcommand.parse(
            [fixture.bundleURL.path, root.appendingPathComponent("missing.tsv").path, "--format", "json"]
        )
        let noFileEvents = try await CLIEventTranscriptCoverageTests.eventLines(expectingFailure: true) { try await noFile.execute(emit: $0) }
        XCTAssertTrue(try Self.words(of: noFileEvents).last?.hasPrefix("failed: No sample metadata file at") == true)
        let noBundle = try VariantsCommand.DeleteSubcommand.parse([root.appendingPathComponent("none.lungfishref").path, "--all", "--format", "json"])
        let noBundleEvents = try await CLIEventTranscriptCoverageTests.eventLines(expectingFailure: true) { try await noBundle.execute(emit: $0) }
        XCTAssertTrue(try Self.words(of: noBundleEvents).last?.hasPrefix("failed: No reference bundle at") == true)
        XCTAssertEqual(try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL]), before)
    }

    func testARowThatIsNotThereDeletesNothingAndWritesNoRecord() async throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let before = try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL])
        let leaf = try VariantsCommand.DeleteSubcommand.parse(
            [fixture.bundleURL.path, "--variant-id=\(VariantEditFixture.trackID):99999", "--format", "json"]
        )
        let events = try await CLIEventTranscriptCoverageTests.eventLines { try await leaf.execute(emit: $0) }
        XCTAssertEqual(try Self.words(of: events).last, "complete: No matching variants. The bundle is unchanged.")
        XCTAssertEqual(try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: [fixture.databaseURL]), before)
    }

    // MARK: - R2 of BIO-Q-A2 (lane 13.27). The caller gives the identity that its record names.

    /// The leaf is the CLI's caller of the writer, so its record names `lungfish-cli` with kind `cli` in every field.
    func testDeletionLeafRecordNamesTheCLI() async throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        try await VariantsCommand.DeleteSubcommand.parse([fixture.bundleURL.path, "--all", "--quiet"]).execute(emit: { _ in })
        try assertRecordNames("lungfish-cli", kind: "cli", argv0: "lungfish-cli", in: fixture)
    }

    /// The table builds the service with the recorded name and kind `gui`. With no argv from its caller the writer starts
    /// the argv with the caller's name (13.27-c4, P-ARGV0-1).
    func testDeletionAppRecordNamesTheApp() throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        _ = try VariantDeletionMutationService(
            toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind
        ).deleteAllVariants(bundleURL: fixture.bundleURL, targets: [tableTarget(fixture)])
        try assertRecordNames("Lungfish Genome Explorer", kind: "gui", argv0: "Lungfish Genome Explorer", in: fixture)
    }

    func testMetadataImportLeafRecordNamesTheCLI() async throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        _ = try fixture.writeMetadata()
        let metadata = fixture.root.appendingPathComponent("metadata.tsv")
        try await VariantsCommand.ImportSampleMetadataSubcommand.parse([fixture.bundleURL.path, metadata.path, "--quiet"])
            .execute(emit: { _ in })
        try assertRecordNames("lungfish-cli", kind: "cli", argv0: "lungfish-cli", in: fixture)
    }

    func testMetadataImportAppRecordNamesTheApp() throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        _ = try fixture.writeMetadata()
        let metadata = fixture.root.appendingPathComponent("metadata.tsv")
        _ = try VariantSampleMetadataImportService(
            toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind
        ).importMetadata(
            from: metadata, format: .tsv, bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: VariantEditFixture.trackID)]
        )
        try assertRecordNames("Lungfish Genome Explorer", kind: "gui", argv0: "Lungfish Genome Explorer", in: fixture)
    }

    /// The record's `toolName`, `tool.name`, `tool.kind`, first step's `toolName` and argv[0] as written.
    private func assertRecordNames(
        _ name: String, kind: String, argv0: String, in fixture: VariantEditFixture, line: UInt = #line
    ) throws {
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        ), line: line)
        XCTAssertEqual(record.toolName, name, line: line)
        XCTAssertEqual(record.tool.name, name, line: line)
        XCTAssertEqual(record.tool.kind, kind, line: line)
        XCTAssertEqual(record.steps.first?.toolName, name, line: line)
        XCTAssertEqual(record.argv.first, argv0, line: line)
    }

    /// The table names the app (`Lungfish Genome Explorer`, `gui`) and the leaf names `lungfish-cli` (`cli`), whoever makes the
    /// edit (R2 of BIO-Q-A2, lane 13.27). The lines at the identity paths of `CallerIdentityPaths`, the list
    /// `RouteParityHarness.appIdentityDifference` declares, differ by design (MD62) and every other line must still agree.
    private func withoutCallerIdentity(_ dump: String) -> String {
        CallerIdentityPaths.removingIdentityLines(from: dump)
    }

    // MARK: - Helpers

    private func tableTarget(_ fixture: VariantEditFixture) -> VariantDeletionMutationTarget {
        VariantDeletionMutationTarget(
            trackId: VariantEditFixture.trackID, databaseURL: fixture.databaseURL, trackName: VariantEditFixture.trackName
        )
    }

    /// One fixture in root `a` and its copy in root `c`.
    private func twoRoots(withMetadata: Bool = false) throws -> (a: VariantEditFixture, c: VariantEditFixture) {
        let rootA = root.appendingPathComponent("a", isDirectory: true)
        let rootC = root.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        let a = try VariantEditFixture.make(in: rootA, withTrackManifest: true)
        if withMetadata { _ = try a.writeMetadata() }
        try FileManager.default.copyItem(at: rootA, to: rootC)
        return (a, a.rebased(onto: rootC))
    }

    /// The rows of the variant database and the main record, with each root's path masked, agree.
    private func assertSameBundle(_ a: VariantEditFixture, _ c: VariantEditFixture, line: UInt = #line) throws {
        XCTAssertEqual(
            try VariantEditDump.rows(of: c.databaseURL), try VariantEditDump.rows(of: a.databaseURL),
            "the leaf leaves the table's rows", line: line
        )
        XCTAssertEqual(
            withoutCallerIdentity(try VariantEditDump.provenance(of: c.bundleURL, root: c.root)),
            withoutCallerIdentity(try VariantEditDump.provenance(of: a.bundleURL, root: a.root)),
            "the leaf writes the table's record", line: line
        )
    }

    /// Each event line as "<event>: <message>".
    private static func words(of lines: [String]) throws -> [String] {
        try lines.map { line in
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return "\(object["event"] as? String ?? "?"): \(object["message"] as? String ?? object["error"] as? String ?? "")"
        }
    }
}
