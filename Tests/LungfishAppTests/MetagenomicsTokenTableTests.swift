// MetagenomicsTokenTableTests.swift - The prefixes and tokens the classifier lists spell out
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A37 (panel decision A10). The import kinds, `build-db`'s tool enum, the sidebar's
// result-folder check and the TaxTriage viewer's related-analysis scan each keep a copy of the
// registry's tokens. This table is the output of all four, written down before any of them reads the
// registry, so the lane that makes them read it changes no value. It asserts what each returns and not
// how it is written.
//
// Kraken2 imports name their folder `classification-` where the registry's prefix is `kraken2-`, NAO-MGS
// imports use the command word `nao-mgs`, and `MetagenomicsImportKind` is `Codable`, so its raw values
// are the stored form. The tables below pin those three as they are.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishTaxTriageUI
@testable import LungfishWorkflow

@MainActor
final class MetagenomicsTokenTableTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetagenomicsTokenTable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Creates the folder at `path` under `root`, with each entry of `contents` inside it. An entry that ends
    /// in a slash is a folder and any other is an empty file.
    @discardableResult
    private func makeFolder(_ path: String, contents: [String], under root: URL) throws -> URL {
        let folder = root.appendingPathComponent(path, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in contents {
            if entry.hasSuffix("/") {
                try fm.createDirectory(at: folder.appendingPathComponent(entry), withIntermediateDirectories: true)
            } else {
                try Data().write(to: folder.appendingPathComponent(entry))
            }
        }
        return folder
    }

    // MARK: - Import kinds

    /// Each kind's stored raw value, tool identifier, folder prefix and `lungfish-cli import` word.
    func testImportKindRawValuesIdentifiersPrefixesAndCommandWords() throws {
        let expected: [(kind: MetagenomicsImportKind, raw: String, prefix: String, command: String)] = [
            (.kraken2, "kraken2", "classification-", "kraken2"),
            (.esviritu, "esviritu", "esviritu-", "esviritu"),
            (.taxtriage, "taxtriage", "taxtriage-", "taxtriage"),
            (.naomgs, "naomgs", "naomgs-", "nao-mgs"),
            (.nvd, "nvd", "nvd-", "nvd"),
        ]
        XCTAssertEqual(MetagenomicsImportKind.allCases, expected.map(\.kind))
        for row in expected {
            XCTAssertEqual(row.kind.rawValue, row.raw, row.raw)
            XCTAssertEqual(row.kind.toolIdentifier, row.raw, row.raw)
            XCTAssertEqual(row.kind.directoryPrefix, row.prefix, row.raw)
            XCTAssertEqual(row.kind.importCommandToken, row.command, row.raw)
            // The stored form is the raw value, so a project that holds it keeps decoding.
            let stored = String(decoding: try JSONEncoder().encode([row.kind]), as: UTF8.self)
            XCTAssertEqual(stored, "[\"\(row.raw)\"]", row.raw)
            XCTAssertEqual(
                try JSONDecoder().decode([MetagenomicsImportKind].self, from: Data("[\"\(row.raw)\"]".utf8)),
                [row.kind], row.raw
            )
            // The identifier is one the registry lists, so the analysis list knows the kind.
            XCTAssertTrue(AnalysesFolder.knownTools.contains(row.kind.toolIdentifier), row.raw)
            XCTAssertNotNil(AnalysisToolRegistry.descriptor(forRawID: row.kind.toolIdentifier), row.raw)
        }
    }

    // MARK: - build-db

    /// The word `lungfish build-db` takes and the workflow name its provenance record carries.
    func testBuildDbProvenanceToolWordsAndWorkflowNames() {
        let expected: [(tool: BuildDbProvenanceTool, id: AnalysisToolID, word: String)] = [
            (.taxTriage, .taxtriage, "taxtriage"),
            (.esViritu, .esviritu, "esviritu"),
            (.kraken2, .kraken2, "kraken2"),
        ]
        for row in expected {
            XCTAssertEqual(row.tool.rawValue, row.word, row.word)
            XCTAssertEqual(row.tool.workflowName, "lungfish build-db \(row.word)", row.word)
            // The registry's descriptor holds the same word.
            XCTAssertEqual(AnalysisToolRegistry.descriptor(for: row.id)?.buildDatabaseToken, row.word, row.word)
        }
    }

    // MARK: - Sidebar result folders

    /// Which folder names `isMetagenomicsResultDirectory` accepts, with and without the sidecar of their
    /// prefix, and the folders inside `Analyses/` it accepts by their metadata or their files.
    func testSidebarAcceptsAFolderPrefixOnlyWithItsSidecar() throws {
        let rows: [(path: String, contents: [String], accepted: Bool)] = [
            ("taxtriage-AB12CD34", ["taxtriage-result.json"], true),
            ("taxtriage-AB12CD34", ["kraken2/"], true),
            ("taxtriage-AB12CD34", [], false),
            ("taxtriage-AB12CD34", ["esviritu-result.json"], false),
            ("taxtriage_AB12CD34", ["taxtriage-result.json"], false),
            ("classification-2026-01-01T00-00-00", ["classification-result.json"], true),
            ("classification-2026-01-01T00-00-00", [], false),
            ("kraken2-2026-01-01T00-00-00", ["classification-result.json"], false),
            ("esviritu-2026-01-01T00-00-00", ["esviritu-result.json"], true),
            ("esviritu-2026-01-01T00-00-00", [], false),
            ("esviritu-2026-01-01T00-00-00", ["classification-result.json"], false),
            ("naomgs-sample", ["manifest.json"], true),
            ("naomgs-sample", [], false),
            ("nvd-sample", ["manifest.json"], true),
            ("nvd-sample", [], false),
            ("cz-id-sample", ["cz-id-manifest.json"], true),
            ("cz-id-sample", [], false),
            ("cz-id-sample.lungfishtax", ["cz-id-manifest.json"], false),
            ("plain-folder", ["manifest.json"], false),
            ("Analyses/renamed run A", ["analysis-metadata.json"], true),
            ("Analyses/Group/renamed run B", ["analysis-metadata.json"], true),
            ("renamed run C", ["analysis-metadata.json"], false),
            ("Analyses/renamed run D", ["classification-result.json"], true),
            ("Analyses/renamed run E", ["manifest.json", "hits.sqlite"], true),
            ("Analyses/renamed run F", ["manifest.json"], false),
            ("Analyses/Group/renamed run G", ["classification-result.json"], false),
        ]
        for row in rows {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = try makeFolder(row.path, contents: row.contents, under: root)
            XCTAssertEqual(
                SidebarProjectScanner.isMetagenomicsResultDirectory(folder), row.accepted,
                "\(row.path) holding \(row.contents)"
            )
        }
    }
}
