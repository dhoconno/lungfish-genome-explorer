// VariantEditInvocationTests.swift - The command a stored variant edit records, and the cancel of a metadata import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A43 M2, plan decision C3. The drawer and `lungfish-cli variants delete` and
// `variants import-sample-metadata` call these services, and a record must name the command that
// made the edit. With no `invocationArgv` a service writes the `lungfish-gui` form
// (VariantEditPinTests holds that). With one, the record's argv, its reproducible command and its
// step name it. A metadata import also stops at a cancel and leaves every database and record as it
// was (decision C5), at each of the points where it asks.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class VariantEditInvocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variant-edit-invocation")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The argv builders

    func testDeleteArgumentsNameTheBundleAndEachSelectedRowWithItsTrack() {
        let bundle = URL(fileURLWithPath: "/work/My Bundle.lungfishref", isDirectory: true)
        XCTAssertEqual(
            VariantDeletionMutationService.deleteAllArguments(bundleURL: bundle),
            ["variants", "delete", "/work/My Bundle.lungfishref", "--all"]
        )
        XCTAssertEqual(
            VariantDeletionMutationService.deleteSelectedArguments(
                bundleURL: bundle, idsByTrack: ["trackB": [9, 2, 2], "trackA": [5], "empty": []]
            ),
            ["variants", "delete", "/work/My Bundle.lungfishref",
             "--variant-id=trackA:5", "--variant-id=trackB:2", "--variant-id=trackB:9"],
            "tracks in name order, row IDs ascending and once, a track with no row not at all"
        )
    }

    func testSelectionParsesAVariantIDOnItsLastColon() throws {
        XCTAssertEqual(
            try VariantDeletionMutationService.selection(fromVariantIDs: ["a:b:7", "a:b:3", "c:1", "a:b:7"]),
            ["a:b": [3, 7], "c": [1]]
        )
        for bad in ["", "7", ":7", "a:", "a:x", "a:-1"] {
            XCTAssertThrowsError(try VariantDeletionMutationService.selection(fromVariantIDs: [bad]), "'\(bad)' names no variant")
        }
    }

    func testImportMetadataArgumentsNameTheFileAndItsFormat() {
        XCTAssertEqual(
            VariantSampleMetadataImportService.importMetadataArguments(
                metadataURL: URL(fileURLWithPath: "/work/samples.csv"),
                format: .csv,
                bundleURL: URL(fileURLWithPath: "/work/B.lungfishref", isDirectory: true)
            ),
            ["variants", "import-sample-metadata", "/work/B.lungfishref", "/work/samples.csv", "--metadata-format", "csv"]
        )
    }

    // MARK: - The record names the command it is given

    func testSelectedDeletionRecordsTheCommandItIsGivenAndNamesTheRowsThatWent() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let ids = try fixture.variantIDs()
        let selection = ["trackA": [ids[1]]]
        let argv = ["lungfish-cli"]
            + VariantDeletionMutationService.deleteSelectedArguments(bundleURL: fixture.bundleURL, idsByTrack: selection)
        let result = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
            idsByTrack: selection, bundleURL: fixture.bundleURL, targets: [target(of: fixture)], invocationArgv: argv
        )
        XCTAssertEqual(result.totalDeleted, 1)
        let lines = try recordLines(of: fixture)
        try assertRecordNames(argv, in: lines, reproducible: "lungfish-cli variants delete \(fixture.bundleURL.path) --variant-id=trackA:\(ids[1])")
        XCTAssertTrue(lines.contains("options.explicit.scope.value = selected"), "the step keeps its scope")
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("options.explicit.variantIdsByTrack.value.trackA.value[0].value = ") && $0.hasSuffix("\(ids[1])") },
            "the record names the row that went"
        )
        XCTAssertTrue(lines.contains("options.resolvedDefaults.totalDeleted.value = 1"))
    }

    func testDeleteAllRecordsTheCommandItIsGiven() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let argv = ["lungfish-cli"] + VariantDeletionMutationService.deleteAllArguments(bundleURL: fixture.bundleURL)
        let result = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteAllVariants(
            bundleURL: fixture.bundleURL, targets: [target(of: fixture)], invocationArgv: argv
        )
        XCTAssertEqual(result.totalDeleted, 3)
        let lines = try recordLines(of: fixture)
        try assertRecordNames(argv, in: lines, reproducible: "lungfish-cli variants delete \(fixture.bundleURL.path) --all")
        XCTAssertTrue(lines.contains("options.explicit.scope.value = all"))
        XCTAssertTrue(lines.contains("options.resolvedDefaults.totalDeleted.value = 3"))
    }

    func testMetadataImportRecordsTheCommandItIsGiven() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let metadata = try fixture.writeMetadata()
        let argv = ["lungfish-cli"] + VariantSampleMetadataImportService.importMetadataArguments(
            metadataURL: metadata, format: .tsv, bundleURL: fixture.bundleURL
        )
        let result = try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
            from: metadata, format: .tsv, bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "trackA")],
            invocationArgv: argv
        )
        XCTAssertEqual(result.totalUpdated, 2)
        let lines = try recordLines(of: fixture)
        try assertRecordNames(argv, in: lines, reproducible: "lungfish-cli variants import-sample-metadata \(fixture.bundleURL.path) \(metadata.path) --metadata-format tsv")
        XCTAssertTrue(lines.contains("options.explicit.format.value = tsv"), "the step keeps its format option")
    }

    // MARK: - A cancel

    /// The service asks `shouldCancel` after the publication is built, before each chunk of the
    /// copy's hash, before each target's import and before the record is written. The hash asks
    /// before every read, the one that finds the end of the file included, so a file of one chunk
    /// gives two asks. Two targets and that file give six asks. A true answer at any of them throws
    /// `CancellationError` and leaves every database, file and record as it was. A seventh run,
    /// where no ask is true, completes, so the six asks are all of them.
    func testACancelAtAnyAskLeavesTheBundleAsItWas() throws {
        let fixture = try VariantEditFixture.make(in: root)
        let second = try fixture.addDatabase(named: "second.db")
        let metadata = try fixture.writeMetadata()
        let targets = [fixture.databaseURL, second].map { VariantSampleMetadataImportTarget(databaseURL: $0, trackName: "t") }
        let before = try snapshot(of: fixture, databases: [fixture.databaseURL, second])

        for cancelAt in 1...6 {
            var asks = 0
            XCTAssertThrowsError(
                try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
                    from: metadata, format: .tsv, bundleURL: fixture.bundleURL, targets: targets,
                    shouldCancel: { asks += 1; return asks == cancelAt }
                ),
                "a cancel at ask \(cancelAt)"
            ) { XCTAssertTrue($0 is CancellationError, "ask \(cancelAt) throws CancellationError, not \($0)") }
            XCTAssertEqual(asks, cancelAt, "the import stops at the ask that answered true")
            XCTAssertEqual(
                try snapshot(of: fixture, databases: [fixture.databaseURL, second]), before,
                "a cancel at ask \(cancelAt) leaves the rows, the files and the records as they were"
            )
        }

        var asks = 0
        let result = try VariantSampleMetadataImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).importMetadata(
            from: metadata, format: .tsv, bundleURL: fixture.bundleURL, targets: targets,
            shouldCancel: { asks += 1; return false }
        )
        XCTAssertEqual(
            asks, 6,
            "after the publication, before each of two chunk reads of the hash, before each of two targets, and before the record"
        )
        XCTAssertEqual(result.totalUpdated, 4)
    }

    // MARK: - Helpers

    private func target(of fixture: VariantEditFixture) -> VariantDeletionMutationTarget {
        VariantDeletionMutationTarget(trackId: "trackA", databaseURL: fixture.databaseURL, trackName: "Variants")
    }

    private func recordLines(of fixture: VariantEditFixture) throws -> [String] {
        try VariantEditDump.provenance(of: fixture.bundleURL, root: root).components(separatedBy: "\n")
    }

    /// The record's argv, its reproducible command and its step all name `argv`.
    private func assertRecordNames(
        _ argv: [String], in lines: [String], reproducible: String, line: UInt = #line
    ) throws {
        let masked = { (text: String) in text.replacingOccurrences(of: self.root.resolvingSymlinksInPath().path, with: "<ROOT>")
            .replacingOccurrences(of: self.root.path, with: "<ROOT>") }
        for (index, word) in argv.enumerated() {
            XCTAssertTrue(lines.contains("argv[\(index)] = \(masked(word))"), "argv[\(index)] is \(word)", line: line)
            XCTAssertTrue(lines.contains("steps[0].argv[\(index)] = \(masked(word))"), "steps[0].argv[\(index)] is \(word)", line: line)
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("argv[\(argv.count)] =") }, "no word beyond the command", line: line)
        XCTAssertTrue(lines.contains("reproducibleCommand = \(masked(reproducible))"), "the reproducible command", line: line)
        XCTAssertTrue(lines.contains("steps[0].reproducibleCommand = \(masked(reproducible))"), "the step's reproducible command", line: line)
        XCTAssertFalse(lines.joined(separator: "\n").contains("lungfish-gui"), "no word of the GUI form", line: line)
    }

    private func snapshot(of fixture: VariantEditFixture, databases: [URL]) throws -> String {
        try VariantEditDump.snapshot(ofBundleAt: fixture.bundleURL, databases: databases)
    }
}
