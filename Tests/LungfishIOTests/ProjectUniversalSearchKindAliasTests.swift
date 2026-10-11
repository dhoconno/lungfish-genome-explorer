// ProjectUniversalSearchKindAliasTests.swift - Result folders and the words a query calls them by
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision V12. Universal search recognizes a result folder through
// `AnalysesFolder.analysisInfo` and reaches each indexed kind by its analysis id, the group of the
// `lungfish-cli` command that makes it and the name the sidebar shows, in any case and with the
// hyphens left out. Before this, `type:kraken2` passed through as a word no indexer emits and a
// `kraken2-<timestamp>` folder, the name the app gives a Kraken2 run, was never indexed.

import Foundation
import XCTest
@testable import LungfishIO

final class ProjectUniversalSearchKindAliasTests: XCTestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalSearchKindAlias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("Analyses", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let projectURL {
            try? FileManager.default.removeItem(at: projectURL)
        }
    }

    // MARK: - Query words

    /// Every word a query may call an indexed result kind by, written out here and not read from the
    /// table under test. Each kind has its analysis id, the group of the CLI command that makes or
    /// imports it, the name the sidebar shows and the spellings that existed before the table.
    private static let wordsByKind: [(kind: String, words: [String])] = [
        ("classification_result", [
            "kraken2", "Kraken2", "KRAKEN2", "classification", "kraken", "classification_result",
            "Classification-Result",
        ]),
        ("esviritu_result", ["esviritu", "EsViritu", "ESVIRITU", "esviritu_result", "Esviritu-Result"]),
        ("taxtriage_result", ["taxtriage", "TaxTriage", "TAXTRIAGE", "taxtriage_result"]),
        ("naomgs_result", ["naomgs", "nao-mgs", "NAO-MGS", "Nao_Mgs", "NaoMgs", "naomgs_result"]),
        ("nvd_result", ["nvd", "NVD", "Nvd", "nvd_result"]),
    ]

    func testKraken2WordMeansAClassificationResult() {
        XCTAssertEqual(ProjectUniversalSearchQueryParser.parse("type:kraken2").kinds, ["classification_result"])
    }

    func testEveryNameOfAnIndexedResultKindParsesToTheKind() {
        for (kind, words) in Self.wordsByKind {
            for word in words {
                XCTAssertEqual(
                    ProjectUniversalSearchQueryParser.parse("type:\(word)").kinds,
                    [kind],
                    "type:\(word)"
                )
            }
        }
    }

    func testTwoWordsOfOneKindMakeOneFilter() {
        let parsed = ProjectUniversalSearchQueryParser.parse("type:kraken2 type:classification")
        XCTAssertEqual(parsed.kinds, ["classification_result"])
    }

    func testWordsOutsideTheResultKindsKeepTheirMeaning() {
        let expected: [(word: String, kind: String)] = [
            ("fastq", "fastq_dataset"), ("reference", "reference_bundle"), ("vcf", "vcf_track"),
            ("vcf_sample", "vcf_sample"), ("classification_taxon", "classification_taxon"),
            ("kraken_taxon", "classification_taxon"), ("taxtriage_organism", "taxtriage_organism"),
            ("manifest", "manifest_document"), ("virus", "virus_hit"),
            // These are kinds of their own, spelled as the indexer stores them.
            ("naomgs_taxon", "naomgs_taxon"), ("nvd_taxon", "nvd_taxon"),
            // An analysis the index has no indexer for stays a word no row carries.
            ("spades", "spades"), ("cz-id", "cz_id"),
        ]
        for (word, kind) in expected {
            XCTAssertEqual(ProjectUniversalSearchQueryParser.parse("type:\(word)").kinds, [kind], "type:\(word)")
        }
    }

    // MARK: - Result folders

    func testTypeKraken2FindsAKraken2TimestampFolder() throws {
        try makeResultFolder("Analyses/kraken2-2026-03-28T12-00-00", sidecar: "classification-result.json")

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        for query in ["type:kraken2", "type:Kraken2", "type:classification", "type:classification_result"] {
            let results = try index.search(rawQuery: query, limit: 20)
            XCTAssertEqual(results.map(\.kind), ["classification_result"], query)
            XCTAssertEqual(results.first?.url.lastPathComponent, "kraken2-2026-03-28T12-00-00", query)
        }
    }

    func testEachResultKindIsFoundByEveryOfItsWordsInAFolderNamedByItsAnalysisID() throws {
        let timestamp = "2026-03-28T12-00-00"
        try makeResultFolder("Analyses/kraken2-\(timestamp)", sidecar: "classification-result.json")
        try makeResultFolder("Analyses/esviritu-\(timestamp)", sidecar: "esviritu-result.json")
        try makeResultFolder("Analyses/taxtriage-\(timestamp)", sidecar: "taxtriage-result.json")
        try makeNaoMgsFolder("Analyses/naomgs-\(timestamp)")
        try makeNvdFolder("Analyses/nvd-\(timestamp)")

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        for (kind, words) in Self.wordsByKind {
            for word in words {
                let found = try index.search(rawQuery: "type:\(word)", limit: 50)
                XCTAssertEqual(found.map(\.kind), [kind], "type:\(word)")
            }
        }
    }

    func testRenamedFoldersAreFoundThroughTheirAnalysisMetadata() throws {
        let renamed: [(folder: String, sidecar: String, tool: String, kind: String)] = [
            ("Weekly Kraken2 run", "classification-result.json", "kraken2", "classification_result"),
            ("Weekly EsViritu run", "esviritu-result.json", "esviritu", "esviritu_result"),
            ("Weekly TaxTriage run", "taxtriage-result.json", "taxtriage", "taxtriage_result"),
        ]
        for item in renamed {
            try makeResultFolder("Analyses/\(item.folder)", sidecar: item.sidecar)
            try AnalysesFolder.writeAnalysisMetadata(
                AnalysesFolder.AnalysisMetadata(tool: item.tool, isBatch: false),
                to: projectURL.appendingPathComponent("Analyses/\(item.folder)", isDirectory: true)
            )
        }

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        for item in renamed {
            let found = try index.search(rawQuery: "type:\(item.tool)", limit: 20)
            XCTAssertEqual(found.map(\.kind), [item.kind], item.folder)
            XCTAssertEqual(found.first?.url.lastPathComponent, item.folder, item.folder)
        }
    }

    func testARenamedKraken2FolderWithNoMetadataIsFoundByItsSidecar() throws {
        try makeResultFolder("Analyses/Project Alpha Results", sidecar: "classification-result.json")

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20).map(\.kind), ["classification_result"])
    }

    func testTheFolderNamesOfBeforeAreStillIndexed() throws {
        // The names the index recognized by prefix alone, none of them a registered timestamp name.
        try makeResultFolder("classification-20250328-120000", sidecar: "classification-result.json")
        try makeResultFolder("esviritu-20250328-120000", sidecar: "esviritu-result.json")
        try makeResultFolder("taxtriage-20250328-120000", sidecar: "taxtriage-result.json")
        try makeNaoMgsFolder("naomgs-wastewater")
        try makeNvdFolder("nvd-demo")

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        let stats = try index.rebuild()

        for kind in ["classification_result", "esviritu_result", "taxtriage_result", "naomgs_result", "nvd_result"] {
            XCTAssertEqual(stats.perKindCounts[kind], 1, kind)
        }
    }

    func testAFolderWithoutItsSidecarIsNotAResult() throws {
        // A run that left no sidecar has nothing to index, whatever its name says.
        let folder = projectURL.appendingPathComponent("Analyses/kraken2-2026-03-28T12-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "kept".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        let stats = try index.rebuild()

        XCTAssertNil(stats.perKindCounts["classification_result"])
        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20), [])
    }

    func testAResultFolderIsIndexedOnceAndItsFilesAreNotAlsoManifestDocuments() throws {
        try makeResultFolder("Analyses/kraken2-2026-03-28T12-00-00", sidecar: "classification-result.json")

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        let stats = try index.rebuild()

        XCTAssertEqual(stats.perKindCounts["classification_result"], 1)
        XCTAssertNil(stats.perKindCounts["manifest_document"])
    }

    func testUpsertIndexesAKraken2Folder() throws {
        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()
        try makeResultFolder("Analyses/kraken2-2026-03-28T12-00-00", sidecar: "classification-result.json")

        try index.upsertArtifact(
            at: projectURL.appendingPathComponent("Analyses/kraken2-2026-03-28T12-00-00", isDirectory: true)
        )

        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20).map(\.kind), ["classification_result"])
    }

    func testAKraken2FolderInsideAFASTQBundleIsIndexed() throws {
        let bundle = projectURL.appendingPathComponent("HG002.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        try makeResultFolder("HG002.lungfishfastq/derivatives/kraken2-2026-03-28T12-00-00", sidecar: "classification-result.json")

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20).map(\.kind), ["classification_result"])
    }

    func testAKraken2FolderStillWaitsForItsRun() throws {
        let relativePath = "Analyses/kraken2-2026-03-28T12-00-00"
        try makeResultFolder(relativePath, sidecar: "classification-result.json")
        let folder = projectURL.appendingPathComponent(relativePath, isDirectory: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "Kraken2"), in: folder)

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()
        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20), [], "a running analysis is not searchable")

        AnalysisRunRecord.markComplete(folder)
        _ = try index.rebuild()
        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20).map(\.kind), ["classification_result"])
    }

    // MARK: - The table

    func testTheTableHoldsTheFiveKindsTheIndexersStore() {
        XCTAssertEqual(
            ProjectUniversalSearchResultKind.allCases.map(\.kind),
            ["classification_result", "esviritu_result", "taxtriage_result", "naomgs_result", "nvd_result"]
        )
    }

    func testEveryKindNamesARegisteredAnalysisAndTheNameTheSidebarShows() {
        for resultKind in ProjectUniversalSearchResultKind.allCases {
            let descriptor = AnalysisToolRegistry.descriptor(for: resultKind.analysisID)
            XCTAssertNotNil(descriptor, resultKind.kind)
            XCTAssertEqual(resultKind.sidebarName, descriptor?.displayName, resultKind.kind)
        }
    }

    func testEveryOtherRegisteredAnalysisHasNoIndexerAndNoResultWord() {
        let indexed = Set(ProjectUniversalSearchResultKind.allCases.map(\.analysisID))
        XCTAssertEqual(Set(indexed.map(\.rawValue)), ["kraken2", "esviritu", "taxtriage", "naomgs", "nvd"])
        for descriptor in AnalysisToolRegistry.all where !indexed.contains(descriptor.id) {
            let id = descriptor.id.rawValue
            XCTAssertNil(ProjectUniversalSearchResultKind(queryWord: id), id)
            XCTAssertNil(ProjectUniversalSearchResultKind(queryWord: descriptor.displayName), id)
        }
    }

    func testNoWordNamesTwoKinds() {
        var owners: [String: String] = [:]
        for resultKind in ProjectUniversalSearchResultKind.allCases {
            for word in resultKind.queryWords {
                if let owner = owners[word] {
                    XCTFail("\(word) names both \(owner) and \(resultKind.kind)")
                }
                owners[word] = resultKind.kind
            }
        }
    }

    func testASquashedWordIgnoresCaseHyphensUnderscoresAndSpaces() {
        XCTAssertEqual(ProjectUniversalSearchResultKind.squash("NAO-MGS"), "naomgs")
        XCTAssertEqual(ProjectUniversalSearchResultKind.squash("Nao_Mgs Result"), "naomgsresult")
        XCTAssertEqual(ProjectUniversalSearchResultKind(queryWord: "Nao Mgs"), .naomgs)
        XCTAssertNil(ProjectUniversalSearchResultKind(queryWord: "naomgs_taxon"))
    }

    // MARK: - Recognizing a folder

    func testTheNameClaimsAFolderThatHoldsTwoSidecars() throws {
        // A NAO-MGS bundle and an NVD bundle both hold manifest.json and hits.sqlite.
        let naoMgs = try makeBundleFolder("Analyses/naomgs-wastewater", manifest: #"{"taxonCount":3}"#)
        let nvd = try makeBundleFolder("Analyses/nvd-demo", manifest: #"{"experiment":"100"}"#)

        XCTAssertEqual(ProjectUniversalSearchResultKind.recognize(directory: naoMgs), .naomgs)
        XCTAssertEqual(ProjectUniversalSearchResultKind.recognize(directory: nvd), .nvd)
    }

    func testAnalysisInfoTellsTwoRenamedBundlesApart() throws {
        let naoMgs = try makeBundleFolder("Analyses/Wastewater week 12", manifest: #"{"taxonCount":3}"#)
        let nvd = try makeBundleFolder("Analyses/Novel virus screen", manifest: #"{"experiment":"100"}"#)

        XCTAssertEqual(ProjectUniversalSearchResultKind.recognize(directory: naoMgs), .naomgs)
        XCTAssertEqual(ProjectUniversalSearchResultKind.recognize(directory: nvd), .nvd)
    }

    func testACZIDImportHoldsAClassificationSidecarAndIsNotAKraken2Result() throws {
        // convertTaxonReport writes classification-result.json beside cz-id-manifest.json.
        let folder = projectURL.appendingPathComponent("Analyses/Cornea import", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("classification-result.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appendingPathComponent("cz-id-manifest.json"), atomically: true, encoding: .utf8)

        XCTAssertNil(ProjectUniversalSearchResultKind.recognize(directory: folder))
    }

    func testAKraken2BatchRootIsNotAResultButItsSampleFolderIs() throws {
        let batch = projectURL.appendingPathComponent("Analyses/kraken2-batch-2026-03-28T12-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try "{}".write(to: batch.appendingPathComponent("classification-batch-result.json"), atomically: true, encoding: .utf8)
        try makeResultFolder("Analyses/kraken2-batch-2026-03-28T12-00-00/HG002", sidecar: "classification-result.json")

        XCTAssertNil(ProjectUniversalSearchResultKind.recognize(directory: batch))
        XCTAssertEqual(
            ProjectUniversalSearchResultKind.recognize(directory: batch.appendingPathComponent("HG002", isDirectory: true)),
            .classification
        )

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()
        XCTAssertEqual(try index.search(rawQuery: "type:kraken2", limit: 20).map(\.kind), ["classification_result"])
    }

    // MARK: - Fixtures

    /// A folder holding the one sidecar file an indexer reads, with an empty JSON object in it.
    private func makeResultFolder(_ relativePath: String, sidecar: String) throws {
        let folder = projectURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent(sidecar), atomically: true, encoding: .utf8)
    }

    /// A folder holding `manifest.json` with the given text and an empty `hits.sqlite`, as a NAO-MGS or
    /// NVD bundle does.
    private func makeBundleFolder(_ relativePath: String, manifest: String) throws -> URL {
        let folder = projectURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("hits.sqlite").path, contents: Data())
        return folder
    }

    private func makeNaoMgsFolder(_ relativePath: String) throws {
        let folder = projectURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = NaoMgsManifest(
            sampleName: "wastewater-1", sourceFilePath: "virus_hits_final.tsv.gz", hitCount: 3, taxonCount: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    private func makeNvdFolder(_ relativePath: String) throws {
        let folder = projectURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NvdDatabase.create(at: folder.appendingPathComponent("hits.sqlite"), hits: [], samples: [])
    }
}
