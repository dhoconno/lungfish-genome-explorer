// VariantsCallAlignmentTrackResolutionTests.swift - `--alignment-track` accepts an id or a unique name, and misses are input errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore

final class VariantsCallAlignmentTrackResolutionTests: XCTestCase {
    private func manifest(_ tracks: [(id: String, name: String)]) -> BundleManifest {
        BundleManifest(
            name: "Fixture",
            identifier: "test.fixture",
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            alignments: tracks.map {
                AlignmentTrackInfo(id: $0.id, name: $0.name, sourcePath: "alignments/\($0.id).bam", indexPath: "alignments/\($0.id).bam.bai")
            }
        )
    }

    private func inputErrorMessage(_ block: () throws -> String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            let id = try block()
            XCTFail("resolved to \(id) instead of failing", file: file, line: line)
            return nil
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, .inputError, "documented exit status 3 for an input error", file: file, line: line)
            return error.localizedDescription
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    func testIdentifierWinsOverAName() throws {
        let manifest = manifest([(id: "aln_1", name: "Sample A"), (id: "aln_2", name: "aln_1")])
        XCTAssertEqual(try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("aln_1", in: manifest), "aln_1")
        XCTAssertEqual(try VariantsCommand.CallSubcommand.resolveAlignmentTrackID(" aln_2 ", in: manifest), "aln_2")
    }

    func testUniqueDisplayNameResolvesToItsIdentifier() throws {
        let manifest = manifest([(id: "aln_1", name: "Sample A"), (id: "aln_2", name: "Sample B")])
        XCTAssertEqual(try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("Sample B", in: manifest), "aln_2")
        XCTAssertEqual(try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("sample b", in: manifest), "aln_2", "case-insensitive when no exact-case name matches")
    }

    func testAmbiguousDisplayNameIsAnInputErrorNamingTheIdentifiers() {
        let manifest = manifest([(id: "aln_1", name: "Sample"), (id: "aln_2", name: "Sample")])
        let message = inputErrorMessage { try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("Sample", in: manifest) }
        XCTAssertTrue(message?.contains("matches 2 tracks") == true, message ?? "")
        XCTAssertTrue(message?.contains("aln_1, aln_2") == true, message ?? "")
    }

    func testUnknownTrackIsAnInputErrorListingTheAvailableTracks() {
        let manifest = manifest([(id: "aln_1", name: "Sample A")])
        let message = inputErrorMessage { try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("aln_9", in: manifest) }
        XCTAssertTrue(message?.contains("Alignment track 'aln_9' not found") == true, message ?? "")
        XCTAssertTrue(message?.contains("aln_1 (Sample A)") == true, message ?? "")

        let empty = inputErrorMessage { try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("aln_9", in: self.manifest([])) }
        XCTAssertTrue(empty?.contains("has no alignment tracks") == true, empty ?? "")
    }

    func testMissingBundleIsAnInputError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).lungfishref")
        _ = inputErrorMessage { try VariantsCommand.CallSubcommand.resolveAlignmentTrackID("aln_1", bundleURL: missing) }
    }

    func testHelpDocumentsTheDisplayNameForm() {
        XCTAssertTrue(VariantsCommand.CallSubcommand.helpMessage(columns: 10_000).contains("or its display name when only one track has that name"))
    }
}
