// DatabaseIdentityStatusReaderTests.swift - Every released database status word reads as one status
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B13, decision R3 and row 257 of the Phase 2.8 plan. Three writers record the status of a database's
// identity under their own words, and a released build never changes a word it wrote. `DatabaseIdentityStatus` reads
// every one of them as one of three statuses (`init(recordedWord:)`), and `DatabaseReceiptPlaceholder` is the one rule
// for the words an install receipt writes when it knows no catalog entry or version. These tests read the words from
// the records and the writers themselves, one test for each released word, so a writer that gains a word with no
// reader fails here, and show that the writers kept their words.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class DatabaseIdentityStatusReaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "database-identity-status")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Helpers

    private var repository: URL { ProvenanceCompatCorpus.repositoryRoot }

    /// Every value recorded under `databaseIdentityStatus` in the JSON file at `path` of the repository, wherever in
    /// the file the key sits (a record's resolved defaults, a step's resolved options, a facts file).
    private func recordedStatusWords(inFile path: String) throws -> Set<String> {
        func collect(_ value: Any) -> [String] {
            if let dictionary = value as? [String: Any] {
                let own = ((dictionary["databaseIdentityStatus"] as? [String: Any])?["value"] as? String).map { [$0] } ?? []
                return own + dictionary.values.flatMap(collect)
            }
            return (value as? [Any])?.flatMap(collect) ?? []
        }
        let data = try Data(contentsOf: repository.appendingPathComponent(path))
        return Set(collect(try JSONSerialization.jsonObject(with: data)))
    }

    /// A Kraken 2 database folder with its three core files.
    private func makeDatabase() throws -> URL {
        let folder = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try Data(repeating: 0x2A, count: 9).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    /// Writes the released install receipt of a Kraken 2 database fixture into `database`, naming that folder as its
    /// final path, with the catalog id, the requested catalog version and the workflow version given.
    private func writeReceipt(
        into database: URL,
        catalogID: String,
        requestedCatalogVersion: String,
        workflowVersion: String
    ) throws {
        let fixture = repository.appendingPathComponent(
            "Tests/Fixtures/provenance-compat/cases/s1-db-receipt-kraken2-viral/managed-storage/databases/kraken2/viral/.lungfish-provenance.json"
        )
        var receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var options = try XCTUnwrap(receipt["options"] as? [String: Any])
        var explicit = try XCTUnwrap(options["explicit"] as? [String: Any])
        var resolved = try XCTUnwrap(options["resolvedDefaults"] as? [String: Any])
        func typed(_ value: String) -> [String: Any] { ["type": "string", "value": value] }
        explicit["catalogID"] = typed(catalogID)
        resolved["intendedFinalPath"] = typed(database.standardizedFileURL.path)
        resolved["requestedSourceURL"] = typed("https://genome-idx.s3.amazonaws.com/kraken/k2_viral_20240904.tar.gz")
        resolved["databaseSourcePolicy"] = typed("unpinnedArchive")
        resolved["requestedCatalogVersion"] = typed(requestedCatalogVersion)
        options["explicit"] = explicit
        options["resolvedDefaults"] = resolved
        receipt["options"] = options
        receipt["workflowVersion"] = workflowVersion
        try JSONSerialization.data(withJSONObject: receipt)
            .write(to: database.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
    }

    // MARK: - One test for each released word

    /// `unpinned`, TaxTriage's and EsViritu's word and the status's own. EsViritu's golden holds it, and both writers
    /// spell it from their constants.
    func testUnpinnedReadsAsUnpinned() throws {
        let golden = try recordedStatusWords(inFile: "Tests/Fixtures/golden/classifiers/esviritu/lungfish-provenance.json")

        XCTAssertEqual(golden, ["unpinned"])
        XCTAssertEqual(TaxTriageRecordFacts.databaseIdentityStatus, "unpinned", "TaxTriage keeps its word")
        XCTAssertEqual(EsVirituAnalysisRunTool.databaseIdentityStatus, "unpinned", "EsViritu keeps its word")
        for word in golden.union([TaxTriageRecordFacts.databaseIdentityStatus, EsVirituAnalysisRunTool.databaseIdentityStatus]) {
            XCTAssertEqual(DatabaseIdentityStatus(recordedWord: word), .unpinned, word)
        }
    }

    /// `unresolved-bounded-metadata`, Kraken 2's word for a database with no digest. The writer holds it, which this
    /// test reads as text because the function is private. No classifier golden holds it since lane 13.31 gave the
    /// golden environment a database that LGE installed, and the Kraken 2 golden records `provided-aggregate-digest`.
    func testUnresolvedBoundedMetadataReadsAsUnpinned() throws {
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: "unresolved-bounded-metadata"), .unpinned)
        XCTAssertTrue(try kraken2WriterWords().contains("unresolved-bounded-metadata"), "Kraken 2 keeps its word")
    }

    /// `provided-aggregate-digest`, Kraken 2's word when the run was given the digest of the whole database. Released
    /// since 2026-08-15, it is in the three writer parity facts that record a Kraken 2 run with a digest and, since
    /// lane 13.31, in the Kraken 2 golden, and a digest names the database, so it reads as `pinned`.
    func testProvidedAggregateDigestReadsAsPinned() throws {
        let facts = [
            "kraken2-batch", "kraken2-pipeline-profile", "conda-classify-wrapper",
        ].map { "Tests/Fixtures/provenance-writer-parity/classifiers/\($0).facts.json" }
            + ["Tests/Fixtures/golden/classifiers/kraken2/lungfish-provenance.json"]

        for path in facts {
            XCTAssertEqual(try recordedStatusWords(inFile: path), ["provided-aggregate-digest"], path)
        }
        XCTAssertEqual(DatabaseIdentityStatus(recordedWord: "provided-aggregate-digest"), .pinned)
        XCTAssertTrue(try kraken2WriterWords().contains("provided-aggregate-digest"), "Kraken 2 keeps its word")
    }

    /// The words of the statuses themselves, `pinned`, `unpinned` and `liveSnapshot`, which no writer records yet.
    func testTheStatusesOwnWordsReadAsThemselves() {
        XCTAssertEqual(DatabaseIdentityStatus.allCases.map(\.rawValue), ["pinned", "unpinned", "liveSnapshot"])
        for status in DatabaseIdentityStatus.allCases {
            XCTAssertEqual(DatabaseIdentityStatus(recordedWord: status.rawValue), status)
            XCTAssertEqual(DatabaseIdentityStatus.status(ofRecordedWord: status.rawValue), status, "the function form")
        }
    }

    /// A word no writer records reads as nothing, and the match is exact, so a reader never guesses.
    func testAWordNoWriterRecordsReadsAsNothing() {
        for word in ["", "Unpinned", "UNPINNED", "pinned ", "unresolved", "provided-aggregate-digest-v2", "unknown", "unspecified"] {
            XCTAssertNil(DatabaseIdentityStatus(recordedWord: word), "\"\(word)\"")
        }
    }

    /// Kraken 2 has two words and no others, so every word the writer can record has a reader. A third word added to
    /// the writer fails here until the type reads it.
    func testEveryWordTheKraken2WriterRecordsHasAReader() throws {
        let words = try kraken2WriterWords()

        XCTAssertEqual(words, ["unresolved-bounded-metadata", "provided-aggregate-digest"])
        XCTAssertEqual(words.compactMap(DatabaseIdentityStatus.init(recordedWord:)), [.unpinned, .pinned])
    }

    /// The string literals of `ClassificationPipeline.databaseIdentityStatus(config:)`, in the order written.
    private func kraken2WriterWords() throws -> [String] {
        let source = try String(
            contentsOf: repository.appendingPathComponent("Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func databaseIdentityStatus(config: ClassificationConfig) -> String {"))
        let body = source[start.upperBound...].prefix { $0 != "}" }
        let pieces = body.split(separator: "\"", omittingEmptySubsequences: false)
        return pieces.enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    // MARK: - The placeholder rule

    /// An install receipt writes `unknown`, `unspecified` or an empty string for what it does not know, and none of
    /// them names a catalog entry or a version.
    func testThePlaceholdersAreTheWordsAReceiptWritesForWhatItDoesNotKnow() {
        XCTAssertEqual(DatabaseReceiptPlaceholder.values, ["", "unknown", "unspecified"])
        for word in DatabaseReceiptPlaceholder.values {
            XCTAssertTrue(DatabaseReceiptPlaceholder.isPlaceholder(word), "\"\(word)\"")
            XCTAssertNil(DatabaseReceiptPlaceholder.named(word), "\"\(word)\"")
        }
        XCTAssertNil(DatabaseReceiptPlaceholder.named(nil))
        XCTAssertEqual(DatabaseReceiptPlaceholder.named("kraken2-viral"), "kraken2-viral")
        XCTAssertEqual(DatabaseReceiptPlaceholder.named("20260626"), "20260626")
        XCTAssertFalse(DatabaseReceiptPlaceholder.isPlaceholder("Unknown"), "the match is exact")
    }

    /// A version is the first candidate that names something, so `unspecified` yields to the receipt's own version, and
    /// a receipt that names no version at all yields none.
    func testUnspecifiedIsNotACatalogVersion() {
        typealias Rule = DatabaseReceiptPlaceholder

        XCTAssertEqual(Rule.firstNamed(among: ["unspecified", "20260626"]), "20260626")
        XCTAssertEqual(Rule.firstNamed(among: [nil, "", "unknown", "v2", "v3"]), "v2")
        XCTAssertEqual(Rule.firstNamed(among: ["20260626", "unspecified"]), "20260626")
        XCTAssertNil(Rule.firstNamed(among: ["unspecified", "unknown"]))
        XCTAssertNil(Rule.firstNamed(among: []))
    }

    /// TaxTriage's reader of a receipt applies the rule. A receipt that wrote `unspecified` for the requested version
    /// and `unknown` for its workflow version records no catalog version, and a catalog entry that names something is
    /// still recorded. The status word stays `unpinned`.
    func testAReceiptWithNoVersionAtAllRecordsNoCatalogVersion() throws {
        let database = try makeDatabase()
        try writeReceipt(
            into: database, catalogID: "kraken2-viral", requestedCatalogVersion: "unspecified", workflowVersion: "unknown"
        )

        let identity = TaxTriageRecordFacts.databaseIdentity(at: database)

        XCTAssertEqual(identity["databaseCatalogID"], .string("kraken2-viral"))
        XCTAssertNil(identity["databaseCatalogVersion"], "no version names this database")
        XCTAssertEqual(identity["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertEqual(identity["databaseSourcePolicy"], .string("unpinnedArchive"), "the receipt was read")
    }

    /// The receipt's own version stands when the requested one is `unspecified`, and the requested one wins when it
    /// names a version.
    func testTheFirstVersionThatNamesSomethingIsRecorded() throws {
        let database = try makeDatabase()

        try writeReceipt(
            into: database, catalogID: "unknown", requestedCatalogVersion: "unspecified", workflowVersion: "20260626"
        )
        let own = TaxTriageRecordFacts.databaseIdentity(at: database)
        XCTAssertEqual(own["databaseCatalogVersion"], .string("20260626"))
        XCTAssertNil(own["databaseCatalogID"], "unknown is a placeholder, not a catalog entry")

        try writeReceipt(
            into: database, catalogID: "kraken2-viral", requestedCatalogVersion: "20240904", workflowVersion: "20260626"
        )
        XCTAssertEqual(TaxTriageRecordFacts.databaseIdentity(at: database)["databaseCatalogVersion"], .string("20240904"))
    }
}
