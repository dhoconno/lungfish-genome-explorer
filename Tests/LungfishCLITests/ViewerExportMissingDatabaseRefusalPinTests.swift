// ViewerExportMissingDatabaseRefusalPinTests.swift - the leaves' refusal for a result folder with no database
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.40 M1 (QA 1, UX words W3 and W4). The leaf text stays right for a Terminal, so the app gets its
// own words for the same condition and no leaf changes. Each test points one leaf at a folder that holds no database
// and reads the refusal word for word, the five lines of `NaoMgsCommand+ExportTable.swift`,
// `NvdCommand+ExportContigs.swift`, `EsVirituCommand+ExportDetections.swift`, `TaxTriageCommand+Export.swift` and
// `Kraken2Command+ExportTable.swift`.

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class ViewerExportMissingDatabaseRefusalPinTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingDatabaseRefusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var output: String { folder.appendingPathComponent("out.tsv").path }

    private func assertRefusal(_ error: Error, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((error as? ViewerExportRefusal)?.message, expected, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "a refusal writes no file", file: file, line: line)
    }

    func testNaoMgsLeafRefusesAFolderWithNoDatabase() throws {
        let parsed = try LungfishCLI.parseAsRoot(["nao-mgs", "export", "table", folder.path, "--output", output])
        let command = try XCTUnwrap(parsed as? NaoMgsCommand.ExportTableSubcommand)
        XCTAssertThrowsError(try command.export()) {
            self.assertRefusal(
                $0, "No NAO-MGS database at \(self.folder.path)/hits.sqlite. Pass the NAO-MGS result folder the app opens."
            )
        }
    }

    func testNvdLeafRefusesAFolderWithNoDatabase() throws {
        let parsed = try LungfishCLI.parseAsRoot(["nvd", "export", "contigs", folder.path, "--output", output])
        let command = try XCTUnwrap(parsed as? NvdCommand.ExportContigsSubcommand)
        XCTAssertThrowsError(try command.export()) {
            self.assertRefusal(
                $0, "No NVD database at \(self.folder.path)/hits.sqlite. Pass the NVD result folder the app opens."
            )
        }
    }

    func testEsVirituLeafRefusesAFolderWithNoDatabase() throws {
        let parsed = try LungfishCLI.parseAsRoot(["esviritu", "export", "detections", folder.path, "--output-format", "tsv", "--output", output])
        let command = try XCTUnwrap(parsed as? EsVirituCommand.ExportDetectionsSubcommand)
        XCTAssertThrowsError(try command.export()) {
            self.assertRefusal(
                $0,
                "No EsViritu database at \(self.folder.path)/esviritu.sqlite. Pass the EsViritu result folder the app opens."
            )
        }
    }

    func testTaxTriageLeafRefusesAFolderWithNoDatabase() throws {
        let parsed = try LungfishCLI.parseAsRoot(["taxtriage", "export", "organism-matrix", folder.path, "--output", output])
        let command = try XCTUnwrap(parsed as? TaxTriageCommand.ExportOrganismMatrixSubcommand)
        XCTAssertThrowsError(try command.export()) {
            self.assertRefusal(
                $0,
                "No TaxTriage database at \(self.folder.path)/taxtriage.sqlite. Pass the TaxTriage result folder the app opens."
            )
        }
    }

    func testKraken2LeafRefusesAFolderWithNoResult() throws {
        let parsed = try LungfishCLI.parseAsRoot(["kraken2", "export", "table", folder.path, "--output-format", "tsv", "--output", output])
        let command = try XCTUnwrap(parsed as? Kraken2Command.ExportTableSubcommand)
        XCTAssertThrowsError(try command.export()) {
            self.assertRefusal(
                $0,
                "No Kraken2 result at \(self.folder.path). Pass kraken2.sqlite, classification-result.json "
                    + "or the result folder the app opens."
            )
        }
    }
}
