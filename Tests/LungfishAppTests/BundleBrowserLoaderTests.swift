// BundleBrowserLoaderTests.swift - Tests for bundle browser summary loading precedence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

final class BundleBrowserLoaderTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleBrowserLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    func testLoadPrefersManifestSummaryOverMirror() throws {
        let fixture = try makeProjectBundle(name: "ManifestPreferred")
        let manifestSummary = makeSummary(
            annotationTrackCount: 7,
            variantTrackCount: 8,
            alignmentTrackCount: 9,
            namesAndLengths: [("chrManifest", 321)]
        )
        let mirrorSummary = makeSummary(
            annotationTrackCount: 1,
            variantTrackCount: 2,
            alignmentTrackCount: 3,
            namesAndLengths: [("chrMirror", 123)]
        )

        let manifest = fixture.manifestWithGenome(browserSummary: manifestSummary)
        let store = try BundleBrowserMirrorStore(projectURL: fixture.projectURL)
        try store.upsert(
            summary: mirrorSummary,
            bundleKey: BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: manifest)
        )

        let result = try BundleBrowserLoader().load(bundleURL: fixture.bundleURL, manifest: manifest)

        XCTAssertEqual(result.source, .manifest)
        XCTAssertEqual(result.summary, manifestSummary)
    }

    func testLoadFallsBackToMirrorThenSynthesizedSummaryAfterMirrorDeletion() throws {
        let fixture = try makeProjectBundle(name: "MirrorFallback")
        let manifest = fixture.manifestWithGenome(browserSummary: nil)
        let mirrorSummary = makeSummary(
            annotationTrackCount: 5,
            variantTrackCount: 4,
            alignmentTrackCount: 3,
            namesAndLengths: [("chrMirror", 777)]
        )
        let key = BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: manifest)

        let store = try BundleBrowserMirrorStore(projectURL: fixture.projectURL)
        try store.upsert(summary: mirrorSummary, bundleKey: key)

        let fromMirror = try BundleBrowserLoader().load(bundleURL: fixture.bundleURL, manifest: manifest)
        XCTAssertEqual(fromMirror.source, .mirror)
        XCTAssertEqual(fromMirror.summary, mirrorSummary)

        let mirrorDBURL = fixture.projectURL
            .appendingPathComponent(".lungfish-cache", isDirectory: true)
            .appendingPathComponent("bundle-browser.sqlite")
        try FileManager.default.removeItem(at: mirrorDBURL)

        let synthesized = try BundleBrowserLoader().load(bundleURL: fixture.bundleURL, manifest: manifest)

        XCTAssertEqual(synthesized.source, .synthesized)
        XCTAssertEqual(synthesized.summary.aggregate.annotationTrackCount, manifest.annotations.count)
        XCTAssertEqual(synthesized.summary.aggregate.variantTrackCount, manifest.variants.count)
        XCTAssertEqual(synthesized.summary.aggregate.alignmentTrackCount, manifest.alignments.count)
        XCTAssertEqual(synthesized.summary.aggregate.totalMappedReads, 25)
        XCTAssertEqual(synthesized.summary.sequences.map(\.name), ["chr1", "chrM"])
        XCTAssertEqual(synthesized.summary.sequences.map(\.length), [1000, 250])

        let reloadedStore = try BundleBrowserMirrorStore(projectURL: fixture.projectURL)
        let persisted = try reloadedStore.fetch(bundleKey: key)
        XCTAssertEqual(persisted, synthesized.summary)
    }

    func testLoadSynthesizesVariantOnlyRowsWhenGenomeMissing() throws {
        let fixture = try makeProjectBundle(name: "VariantOnly")
        let variantDBURL = fixture.bundleURL
            .appendingPathComponent("variants", isDirectory: true)
            .appendingPathComponent("variants.sqlite")
        try FileManager.default.createDirectory(
            at: variantDBURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createVariantDatabase(
            at: variantDBURL,
            records: [
                ("segmentB", 10, 250),
                ("segmentA", 5, 600),
                ("segmentA", 650, 900),
            ]
        )

        let manifest = fixture.manifestVariantOnly(databasePath: "variants/variants.sqlite")

        let result = try BundleBrowserLoader().load(bundleURL: fixture.bundleURL, manifest: manifest)

        XCTAssertEqual(result.source, .synthesized)
        XCTAssertEqual(result.summary.aggregate.annotationTrackCount, 0)
        XCTAssertEqual(result.summary.aggregate.variantTrackCount, 1)
        XCTAssertEqual(result.summary.aggregate.alignmentTrackCount, 0)
        XCTAssertNil(result.summary.aggregate.totalMappedReads)
        XCTAssertEqual(result.summary.sequences.map(\.name), ["segmentA", "segmentB"])
        XCTAssertEqual(result.summary.sequences.map(\.length), [1000, 1000])
        XCTAssertTrue(result.summary.sequences.allSatisfy { $0.metrics == nil })
    }

    func testLoadFallsBackToSynthesisWhenMirrorStoreOpenFails() throws {
        let fixture = try makeProjectBundle(name: "MirrorFailureFallback")
        let manifest = fixture.manifestWithGenome(browserSummary: nil)

        let loader = BundleBrowserLoader(
            mirrorStoreFactory: { _ in
                throw BundleBrowserMirrorStoreError.openFailed("simulated mirror failure")
            }
        )

        let result = try loader.load(bundleURL: fixture.bundleURL, manifest: manifest)

        XCTAssertEqual(result.source, .synthesized)
        XCTAssertEqual(result.summary.sequences.map(\.name), ["chr1", "chrM"])
        XCTAssertEqual(result.summary.aggregate.totalMappedReads, 25)
    }

    func testVariantDatabaseChangesInvalidateMirrorKey() throws {
        let fixture = try makeProjectBundle(name: "VariantKeyInvalidation")
        let variantDBURL = fixture.bundleURL
            .appendingPathComponent("variants", isDirectory: true)
            .appendingPathComponent("variants.sqlite")
        try FileManager.default.createDirectory(
            at: variantDBURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createVariantDatabase(
            at: variantDBURL,
            records: [
                ("segmentA", 5, 200),
            ]
        )

        let manifest = fixture.manifestVariantOnly(databasePath: "variants/variants.sqlite")
        let originalKey = BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: manifest)
        let first = try BundleBrowserLoader().load(bundleURL: fixture.bundleURL, manifest: manifest)
        XCTAssertEqual(first.source, .synthesized)
        XCTAssertEqual(first.summary.sequences.map(\.length), [1000])

        let cachedOriginal = try BundleBrowserMirrorStore(projectURL: fixture.projectURL).fetch(bundleKey: originalKey)
        XCTAssertEqual(cachedOriginal, first.summary)

        try appendVariantRecord(
            at: variantDBURL,
            chromosome: "segmentA",
            position: 250,
            end: 4_000
        )
        let updatedKey = BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: manifest)
        XCTAssertNotEqual(updatedKey, originalKey)

        let second = try BundleBrowserLoader().load(bundleURL: fixture.bundleURL, manifest: manifest)

        XCTAssertEqual(second.source, .synthesized)
        XCTAssertEqual(second.summary.sequences.map(\.length), [4_400])
        let cachedUpdated = try BundleBrowserMirrorStore(projectURL: fixture.projectURL).fetch(bundleKey: updatedKey)
        XCTAssertEqual(cachedUpdated, second.summary)
    }

    func testVariantOnlySynthesisThrowsWhenDeclaredDatabaseIsUnreadable() throws {
        let fixture = try makeProjectBundle(name: "VariantOnlyUnreadable")
        let manifest = fixture.manifestVariantOnly(databasePath: "variants/missing.sqlite")

        XCTAssertThrowsError(
            try BundleSequenceSummarySynthesizer.summarize(bundleURL: fixture.bundleURL, manifest: manifest)
        )
    }

    func testVariantDatabaseWALSidecarChangesInvalidateMirrorKey() throws {
        let fixture = try makeProjectBundle(name: "VariantWALInvalidation")
        let variantDBURL = fixture.bundleURL
            .appendingPathComponent("variants", isDirectory: true)
            .appendingPathComponent("variants.sqlite")
        try FileManager.default.createDirectory(
            at: variantDBURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let db = try openVariantDatabaseForWAL(at: variantDBURL)
        defer { sqlite3_close(db) }
        try createVariantDatabaseSchema(in: db)
        try insertVariantRecord(into: db, chromosome: "segmentA", position: 5, end: 200, variantID: "var-0")

        let manifest = fixture.manifestVariantOnly(databasePath: "variants/variants.sqlite")
        let originalKey = BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: manifest)

        try insertVariantRecord(into: db, chromosome: "segmentA", position: 250, end: 4_000, variantID: "var-1")
        let walURL = URL(fileURLWithPath: variantDBURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))

        let updatedKey = BundleBrowserLoader.bundleKey(for: fixture.bundleURL, manifest: manifest)

        XCTAssertNotEqual(updatedKey, originalKey)
    }

    private func makeProjectBundle(name: String) throws -> FixturePaths {
        let projectURL = tempDirectory.appendingPathComponent("\(name).lungfish", isDirectory: true)
        let bundleURL = projectURL
            .appendingPathComponent("Bundles", isDirectory: true)
            .appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return FixturePaths(projectURL: projectURL, bundleURL: bundleURL)
    }

    private func makeSummary(
        annotationTrackCount: Int,
        variantTrackCount: Int,
        alignmentTrackCount: Int,
        namesAndLengths: [(String, Int64)]
    ) -> BundleBrowserSummary {
        BundleBrowserSummary(
            schemaVersion: 1,
            aggregate: .init(
                annotationTrackCount: annotationTrackCount,
                variantTrackCount: variantTrackCount,
                alignmentTrackCount: alignmentTrackCount,
                totalMappedReads: nil
            ),
            sequences: namesAndLengths.map { name, length in
                BundleBrowserSequenceSummary(
                    name: name,
                    displayDescription: nil,
                    length: length,
                    aliases: [],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: nil
                )
            }
        )
    }

    private func createVariantDatabase(
        at url: URL,
        records: [(chromosome: String, position: Int, end: Int)]
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw XCTSkip("Failed to create SQLite fixture at \(url.path)")
        }
        defer { sqlite3_close(db) }

        try createVariantDatabaseSchema(in: db)

        for (index, record) in records.enumerated() {
            try insertVariantRecord(
                into: db,
                chromosome: record.chromosome,
                position: record.position,
                end: record.end,
                variantID: "var-\(index)"
            )
        }
    }

    private func createVariantDatabaseSchema(in db: OpaquePointer?) throws {
        let createSQL = """
        CREATE TABLE variants (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chromosome TEXT NOT NULL,
            position INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            variant_id TEXT NOT NULL,
            ref TEXT NOT NULL,
            alt TEXT NOT NULL,
            variant_type TEXT NOT NULL,
            quality REAL,
            filter TEXT,
            info TEXT,
            sample_count INTEGER DEFAULT 0
        );
        CREATE TABLE genotypes (
            variant_id INTEGER NOT NULL,
            sample_name TEXT NOT NULL,
            genotype TEXT,
            allele1 INTEGER NOT NULL,
            allele2 INTEGER NOT NULL,
            is_phased INTEGER NOT NULL,
            depth INTEGER,
            genotype_quality INTEGER,
            allele_depths TEXT,
            raw_fields TEXT
        );
        CREATE TABLE samples (
            name TEXT PRIMARY KEY,
            metadata_json TEXT
        );
        CREATE TABLE variant_info (
            variant_id INTEGER NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE variant_info_defs (
            key TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            number TEXT NOT NULL,
            description TEXT
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT INTO db_metadata (key, value) VALUES ('schema_version', '3');
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db)!)
            throw XCTSkip(message)
        }
    }

    private func insertVariantRecord(
        into db: OpaquePointer?,
        chromosome: String,
        position: Int,
        end: Int,
        variantID: String
    ) throws {
        let insertSQL = """
        INSERT INTO variants (
            chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
        ) VALUES (?, ?, ?, ?, 'A', 'T', 'SNP', NULL, NULL, NULL, 0)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db)!)
            throw XCTSkip(message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, (chromosome as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, Int64(position))
        sqlite3_bind_int64(statement, 3, Int64(end))
        sqlite3_bind_text(statement, 4, (variantID as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db)!)
            throw XCTSkip(message)
        }
    }

    private func appendVariantRecord(
        at url: URL,
        chromosome: String,
        position: Int,
        end: Int
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else {
            throw XCTSkip("Failed to reopen SQLite fixture at \(url.path)")
        }
        defer { sqlite3_close(db) }

        try insertVariantRecord(
            into: db,
            chromosome: chromosome,
            position: position,
            end: end,
            variantID: "var-appended-\(end)"
        )

        let updatedDate = Date(timeIntervalSinceNow: 2)
        try FileManager.default.setAttributes([.modificationDate: updatedDate], ofItemAtPath: url.path)
    }

    private func openVariantDatabaseForWAL(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else {
            throw XCTSkip("Failed to create WAL SQLite fixture at \(url.path)")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL;", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw XCTSkip("Failed to enable WAL mode at \(url.path)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_close(db)
            throw XCTSkip("Failed to read WAL mode response at \(url.path)")
        }
        return db
    }

    private struct FixturePaths {
        let projectURL: URL
        let bundleURL: URL

        func manifestWithGenome(browserSummary: BundleBrowserSummary?) -> BundleManifest {
            BundleManifest(
                name: "Fixture",
                identifier: "org.lungfish.fixture",
                modifiedDate: Date(timeIntervalSince1970: 1_713_744_000),
                source: SourceInfo(organism: "Test organism", assembly: "fixture"),
                genome: GenomeInfo(
                    path: "genome/sequence.fa.gz",
                    indexPath: "genome/sequence.fa.gz.fai",
                    totalLength: 1_250,
                    chromosomes: [
                        ChromosomeInfo(
                            name: "chr1",
                            length: 1000,
                            offset: 0,
                            lineBases: 80,
                            lineWidth: 81,
                            aliases: ["1"],
                            fastaDescription: "Primary chromosome"
                        ),
                        ChromosomeInfo(
                            name: "chrM",
                            length: 250,
                            offset: 1001,
                            lineBases: 80,
                            lineWidth: 81,
                            aliases: ["MT"],
                            isPrimary: false,
                            isMitochondrial: true,
                            fastaDescription: "Mitochondrion"
                        )
                    ]
                ),
                annotations: [
                    AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb")
                ],
                variants: [
                    VariantTrackInfo(
                        id: "snps",
                        name: "SNPs",
                        path: "variants/snps.bcf",
                        indexPath: "variants/snps.bcf.csi"
                    )
                ],
                alignments: [
                    AlignmentTrackInfo(
                        id: "reads",
                        name: "reads.bam",
                        format: .bam,
                        sourcePath: "/tmp/reads.bam",
                        indexPath: "/tmp/reads.bam.bai",
                        mappedReadCount: 25
                    )
                ],
                browserSummary: browserSummary
            )
        }

        func manifestVariantOnly(databasePath: String) -> BundleManifest {
            BundleManifest(
                name: "Variant Only Fixture",
                identifier: "org.lungfish.variant-only",
                modifiedDate: Date(timeIntervalSince1970: 1_713_744_100),
                source: SourceInfo(organism: "Virus", assembly: "variant-only"),
                genome: nil,
                variants: [
                    VariantTrackInfo(
                        id: "variants",
                        name: "Variants",
                        path: "variants/variants.bcf",
                        indexPath: "variants/variants.bcf.csi",
                        databasePath: databasePath
                    )
                ]
            )
        }
    }
}
