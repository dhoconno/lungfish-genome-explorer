// EsVirituDatabaseIdentityRecordTests.swift - The EsViritu record cites its database's install receipt
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// DB-IDENTITY, lane DBID of Phase 3.1 (BIO-DB-IDENTITY sections 3 and 5). The record of an EsViritu run cites the
/// install receipt of its database, the payload aggregate SHA-256 the install computed, and hashes no database file
/// at run time. The tests lay the database out as it sits on galah. The receipt is in `esviritu-viral-db` and the
/// files are in its `v3.2.4/` folder, which is the folder `EsVirituDatabaseManager.databaseURL` returns. A stand-in
/// EsViritu writes the tables of one `esviritu-mini` sample, so no real tool runs.
final class EsVirituDatabaseIdentityRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-db-identity").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private static var fixtureTables: URL {
        BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-mini/SRR35517705/SRR35517705")
    }

    private static let coreSizes: [String: ParameterValue] = [
        "virus_pathogen_database.all_metadata.tsv": .integer(4),
        "virus_pathogen_database.fna": .integer(5),
        "virus_pathogen_database.mmi": .integer(6),
    ]

    // MARK: - The record

    /// The receipt sits one folder above the files the tool reads. The record carries the receipt's aggregate as
    /// `databaseDigest` and as the one reference input, names the version the receipt names, and says `pinned`.
    func testEsVirituRecordCitesInstallReceiptDigest() async throws {
        let install = try makeInstall()
        let snapshot = try install.writeReceipt(catalogVersion: "v3.2.4")
        let record = try await runRecord(on: install)

        let resolved = record.options.resolvedDefaults
        XCTAssertEqual(resolved["databaseDigest"], .string(snapshot.aggregateSHA256))
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("pinned"))
        XCTAssertEqual(resolved["databaseCatalogVersion"], .string("v3.2.4"))
        XCTAssertEqual(resolved["databasePath"], .string(install.database.path), "the folder the tool read")
        XCTAssertNil(resolved["databaseIdentityNote"])
        XCTAssertEqual(resolved["databaseCoreFileSizes"], .dictionary(Self.coreSizes), "the sizes stay as they were")

        let references = record.files.filter { $0.role == .reference }
        XCTAssertEqual(references.count, 1, "\(references.map(\.path))")
        let reference = try XCTUnwrap(references.first)
        XCTAssertEqual(reference.path, install.receiptRoot.path, "the folder the aggregate covers")
        XCTAssertEqual(reference.checksumSHA256, snapshot.aggregateSHA256)
        XCTAssertEqual(reference.fileSize, snapshot.totalSizeBytes)
        XCTAssertEqual(reference.sourceProvenancePath, install.receiptURL.path)

        let step = try XCTUnwrap(record.steps.first { $0.toolName == "EsViritu" })
        XCTAssertEqual(step.inputs.filter { $0.role == .reference }.map(\.checksumSHA256), [snapshot.aggregateSHA256])
    }

    /// The receipt names what is installed, and the bundled catalog names what this build would install. An older
    /// install records its own version.
    func testEsVirituRecordReadsItsVersionFromTheReceipt() async throws {
        let install = try makeInstall()
        try install.writeReceipt(catalogVersion: "v3.2.3")
        let record = try await runRecord(on: install)

        XCTAssertEqual(record.options.resolvedDefaults["databaseCatalogVersion"], .string("v3.2.3"))
        XCTAssertEqual(record.options.resolvedDefaults["databaseIdentityStatus"], .string("pinned"))
    }

    /// A database with no receipt keeps the record it had. It says `unpinned`, holds no digest and no reference
    /// input, and its core file sizes name it. This pin passes at the base.
    func testEsVirituRecordWithoutReceiptStaysUnpinned() async throws {
        let install = try makeInstall()
        let record = try await runRecord(on: install)

        let resolved = record.options.resolvedDefaults
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertNil(resolved["databaseDigest"])
        XCTAssertNil(resolved["databaseIdentityNote"], "no receipt, so nothing to say about one")
        XCTAssertEqual(resolved["databaseCoreFileSizes"], .dictionary(Self.coreSizes))
        XCTAssertTrue(record.files.filter { $0.role == .reference }.isEmpty)
    }

    /// A receipt whose listed files do not add up to its own digest vouches for nothing. The record says so in
    /// words and records no digest and no reference input.
    func testEsVirituRecordRefusesReceiptThatDoesNotAddUp() async throws {
        let install = try makeInstall()
        try install.writeReceipt(catalogVersion: "v3.2.4", aggregateOverride: String(repeating: "0", count: 64))
        let record = try await runRecord(on: install)

        let resolved = record.options.resolvedDefaults
        XCTAssertEqual(resolved["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertNil(resolved["databaseDigest"])
        XCTAssertEqual(
            resolved["databaseIdentityNote"],
            .string("The install receipt in \(install.receiptRoot.path) does not add up to its own digest, so this run records no digest.")
        )
        XCTAssertTrue(record.files.filter { $0.role == .reference }.isEmpty)
    }

    // MARK: - The folder the tool reads

    /// Confirmed fact 1 of the ruling. With the registry layout of galah, `databaseURL` returns the `v3.2.4`
    /// folder below `esviritu-viral-db`, one folder under the one that holds the install receipt. This pin passes
    /// at the base.
    func testDatabaseURLReturnsTheVersionFolderBelowTheReceiptRoot() async throws {
        let install = try makeInstall()
        try install.writeReceipt(catalogVersion: "v3.2.4")
        let databasesRoot = install.receiptRoot.deletingLastPathComponent().deletingLastPathComponent()
        let manager = EsVirituDatabaseManager(storageRoot: databasesRoot)
        let isInstalled = await manager.isInstalled()
        let databaseURL = await manager.databaseURL.standardizedFileURL

        XCTAssertTrue(isInstalled)
        XCTAssertEqual(databaseURL.path, install.database.standardizedFileURL.path)
        XCTAssertEqual(
            databaseURL.deletingLastPathComponent().path,
            install.receiptRoot.standardizedFileURL.path,
            "the receipt is in the parent of the folder the tool reads"
        )
    }

    // MARK: - Fixtures

    /// The database laid out as on galah, with no receipt yet.
    private struct Install {
        let receiptRoot: URL
        let database: URL

        var receiptURL: URL { receiptRoot.appendingPathComponent(ProvenanceWriter.provenanceFilename) }

        /// Writes the install receipt over the files below `receiptRoot`, as the installer does, and a file made at
        /// first use after it, as galah's `.fna.fai` is. `aggregateOverride` states a digest the files do not add up to.
        @discardableResult
        func writeReceipt(
            catalogVersion: String,
            aggregateOverride: String? = nil
        ) throws -> MetagenomicsDatabasePayloadSnapshot {
            let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: receiptRoot)
            let outputs = snapshot.files.map { file in
                ProvenanceFileDescriptor(
                    path: receiptRoot.appendingPathComponent(file.path).path,
                    checksumSHA256: file.checksumSHA256,
                    fileSize: file.fileSize,
                    role: .output
                )
            }
            let envelope = ProvenanceEnvelope(
                workflowName: "metagenomics.database.install",
                workflowVersion: catalogVersion,
                toolName: "lungfish",
                toolVersion: "test",
                options: ProvenanceOptions(
                    explicit: ["catalogID": .string("esviritu-viral-v3")],
                    defaults: [:],
                    resolvedDefaults: [
                        "intendedFinalPath": .string(receiptRoot.path),
                        "payloadAggregateSHA256": .string(aggregateOverride ?? snapshot.aggregateSHA256),
                        "payloadTotalSizeBytes": .integer(Int(snapshot.totalSizeBytes)),
                        "requestedCatalogVersion": .string(catalogVersion),
                        "requestedSourceURL": .string("https://example.org/esviritu_db_\(catalogVersion).tar.gz"),
                        "databaseSourcePolicy": .string("unpinnedArchive"),
                    ]
                ),
                output: outputs.first,
                outputs: outputs,
                exitStatus: 0
            )
            _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: receiptRoot)
            try "index\n".write(
                to: database.appendingPathComponent("virus_pathogen_database.fna.fai"), atomically: true, encoding: .utf8
            )
            return snapshot
        }
    }

    private func makeInstall() throws -> Install {
        let receiptRoot = root.appendingPathComponent("esviritu", isDirectory: true)
            .appendingPathComponent("esviritu-viral-db", isDirectory: true)
        let database = receiptRoot.appendingPathComponent("v3.2.4", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let files = [
            ("virus_pathogen_database.fna", "ACGT\n"),
            ("virus_pathogen_database.mmi", "INDEX\n"),
            ("virus_pathogen_database.all_metadata.tsv", "a\tb\n"),
        ]
        for (name, text) in files {
            try text.write(to: database.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return Install(receiptRoot: receiptRoot, database: database)
    }

    private func reads(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).fastq")
        try "@\(name)-1\nACGTACGT\n+\nIIIIIIII\n@\(name)-2\nACGTACGT\n+\nIIIIIIII\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Runs `esviritu detect` on the install as the database the app installed, and returns the record of the run.
    private func runRecord(on install: Install) async throws -> ProvenanceEnvelope {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let parsed = try LungfishCLI.parseAsRoot([
            "esviritu", "detect", "--input", try reads("S1").path, "--sample", "S1", "--output", output.path,
            "--db", install.database.path, "--threads", "2", "--quiet",
        ])
        let command = try XCTUnwrap(parsed as? EsVirituCommand.DetectSubcommand)
        let installed = install.database
        do {
            try await command.execute(
                pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
                materializer: FASTQCLIMaterializer(runner: .shared),
                installedDatabase: { installed }
            )
        } catch let exit as ExitCode {
            XCTFail("esviritu detect exited \(exit.rawValue)")
        }
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
    }
}
