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
        // BIO-DBID SF1. The bundled catalog's URL and policy name the release this build would install, which is not
        // the release the receipt names, so the record leaves both out and cites no other release.
        XCTAssertNil(record.options.resolvedDefaults["databaseSourceURL"], "the bundled catalog's URL names another release")
        XCTAssertNil(record.options.resolvedDefaults["databaseSourcePolicy"])
    }

    /// BIO-DBID SF1, the equal-version case. A receipt that names the version this build bundles keeps the bundled
    /// catalog's source URL and policy, since they describe that same release. The version is read from the lock, so
    /// the test survives a catalog bump.
    func testEsVirituRecordKeepsCatalogSourceWhenReceiptNamesTheBundledVersion() async throws {
        let install = try makeInstall()
        let bundledVersion = ManagedToolLock.bundled.database(id: EsVirituDatabaseManager.catalogID)?.version ?? "v3.2.4"
        try install.writeReceipt(catalogVersion: bundledVersion)
        let record = try await runRecord(on: install)

        XCTAssertEqual(record.options.resolvedDefaults["databaseCatalogVersion"], .string(bundledVersion))
        XCTAssertNotNil(record.options.resolvedDefaults["databaseSourceURL"])
        XCTAssertNotNil(record.options.resolvedDefaults["databaseSourcePolicy"])
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

// MARK: - The methods minimum

/// BIO-DB-IDENTITY section 5, `testEveryClassifierRecordStatesDatabaseIdentity`, the methods-minimum test of lane
/// DBID. It sits in the CLI test target because the EsViritu record can only be made there, and the CLI target reaches
/// every other writer through `LungfishWorkflow` and `LungfishTestSupport`. A run or import of each of the six
/// classifier records is made here, and the facts its record files are read as the Provenance tab reads them.
extension EsVirituDatabaseIdentityRecordTests {
    /// What every record's facts must say. `databaseIdentityStatus` reads as one of the five statuses, and a `pinned`
    /// record carries a 64-hex `databaseDigest`.
    private func assertStatesDatabaseIdentity(
        _ facts: [String: ParameterValue],
        label: String,
        expecting expected: DatabaseIdentityStatus? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let word = facts["databaseIdentityStatus"]?.stringValue else {
            return XCTFail("the \(label) record names no databaseIdentityStatus", file: file, line: line)
        }
        guard let status = DatabaseIdentityStatus(recordedWord: word) else {
            return XCTFail("the \(label) record says \(word), which reads as no status", file: file, line: line)
        }
        if let expected {
            XCTAssertEqual(status, expected, "the \(label) record says \(word)", file: file, line: line)
        }
        if status == .pinned {
            let digest = facts["databaseDigest"]?.stringValue ?? ""
            XCTAssertTrue(
                digest.count == 64 && digest.allSatisfy(\.isHexDigit),
                "the \(label) record says \(word) with the digest \(digest)", file: file, line: line
            )
        }
    }

    /// The six records of 3.1. Kraken2, EsViritu and TaxTriage run over a database whose install receipt adds up, so
    /// each says `pinned` and cites a digest. NVD and CZ-ID name the versions their results state, and NAO-MGS says
    /// its result names none.
    func testEveryClassifierRecordStatesDatabaseIdentity() async throws {
        var records: [(label: String, facts: [String: ParameterValue], expected: DatabaseIdentityStatus)] = []

        let kraken = try FakeClassificationCondaFixture()
        defer { kraken.cleanup() }
        let bare = try kraken.makeConfig(databaseDigest: nil)
        let krakenReceipt = try Install(receiptRoot: bare.databasePath, database: bare.databasePath)
            .writeReceipt(catalogVersion: "2026.1")
        let krakenConfig = try kraken.makeConfig(databaseDigest: krakenReceipt.aggregateSHA256)
        _ = try await ClassificationPipeline(condaManager: kraken.condaManager).classify(config: krakenConfig)
        let krakenRecord = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: krakenConfig.outputDirectory))
        let krakenStep = try XCTUnwrap(krakenRecord.steps.first { $0.toolName == "kraken2" })
        records.append(("Kraken2", krakenStep.resolvedOptions, .pinned))

        let install = try makeInstall()
        try install.writeReceipt(catalogVersion: "v3.2.4")
        let esviritu = try await runRecord(on: install)
        records.append(("EsViritu", esviritu.options.resolvedDefaults, .pinned))
        records.append(("TaxTriage", TaxTriageRecordFacts.databaseIdentity(at: install.receiptRoot), .pinned))

        let imports = root.appendingPathComponent("imports", isDirectory: true)
        let nvd = try await MetagenomicsImportService.importNvd(
            inputURL: try makeNvdRunDirectory(), outputDirectory: imports, samtoolsPath: nil
        )
        records.append(("NVD import", try importedFacts(nvd.resultDirectory), .namedBySource))
        records.append(("NAO-MGS import", try importedFacts(try await importNaoMgsRun(into: imports)), .notNamedBySource))
        let czid = root.appendingPathComponent("czid", isDirectory: true)
        _ = try CzIdDataConverter.convertTaxonReport(
            at: ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/czid/minimal_taxon_report.tsv"),
            outputDirectory: czid
        )
        records.append(("CZ-ID import", try importedFacts(czid), .namedBySource))

        XCTAssertEqual(
            records.map(\.label),
            ["Kraken2", "EsViritu", "TaxTriage", "NVD import", "NAO-MGS import", "CZ-ID import"]
        )
        for record in records {
            assertStatesDatabaseIdentity(record.facts, label: record.label, expecting: record.expected)
        }
    }

    /// The check can fail. A record that names no status, one with a word no reader knows (CZ-ID's released
    /// `unknown`), and a `pinned` one with no 64-hex digest each trip it.
    func testMethodsMinimumCheckTripsOnSilentAndUnbackedRecords() {
        XCTExpectFailure("a record that names no status") {
            assertStatesDatabaseIdentity([:], label: "silent")
        }
        XCTExpectFailure("a word no reader knows") {
            assertStatesDatabaseIdentity(["databaseIdentityStatus": .string("unknown")], label: "placeholder")
        }
        XCTExpectFailure("pinned with no digest") {
            assertStatesDatabaseIdentity(["databaseIdentityStatus": .string("pinned")], label: "pinned without digest")
        }
        XCTExpectFailure("pinned with a short digest") {
            assertStatesDatabaseIdentity(
                ["databaseIdentityStatus": .string("pinned"), "databaseDigest": .string("abc")], label: "short digest"
            )
        }
    }

    private func importedFacts(_ directory: URL) throws -> [String: ParameterValue] {
        try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: directory), "the import wrote no record").options.resolvedDefaults
    }

    /// The NVD run directory `MetagenomicsImportServiceTests` imports, whose rows state `nt-2026` and `stat-1`.
    private func makeNvdRunDirectory() throws -> URL {
        let nvdDir = root.appendingPathComponent("nvd-run", isDirectory: true)
        let labkeyDir = nvdDir.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        let humanVirusDir = nvdDir
            .appendingPathComponent("02_human_viruses", isDirectory: true)
            .appendingPathComponent("03_human_virus_results", isDirectory: true)
        let mappedReadsDir = humanVirusDir.appendingPathComponent("mapped_reads", isDirectory: true)
        try FileManager.default.createDirectory(at: labkeyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mappedReadsDir, withIntermediateDirectories: true)
        let header = "experiment,blast_task,sample_id,qseqid,qlen,sseqid,stitle,tax_rank,length,pident,evalue,bitscore,"
            + "sscinames,staxids,blast_db_version,snakemake_run_id,mapped_reads,total_reads,stat_db_version,"
            + "adjusted_taxid,adjustment_method,adjusted_taxid_name,adjusted_taxid_rank"
        let row = "EXP001,blastn,S1,contig-1,120,gb|NC_001|,Example virus species,S,118,99.2,1e-20,250.5,Example virus,"
            + "12345,nt-2026,run-001,42,100000,stat-1,12345,unchanged,Example virus,species"
        try "\(header)\n\(row)\n".write(
            to: labkeyDir.appendingPathComponent("sample_blast_concatenated.csv"), atomically: true, encoding: .utf8
        )
        try "synthetic bam payload\n".write(
            to: mappedReadsDir.appendingPathComponent("S1.filtered.bam"), atomically: true, encoding: .utf8
        )
        try "synthetic bai payload\n".write(
            to: mappedReadsDir.appendingPathComponent("S1.filtered.bam.bai"), atomically: true, encoding: .utf8
        )
        try ">contig-1\nACGTACGT\n".write(
            to: humanVirusDir.appendingPathComponent("S1.human_virus.fasta"), atomically: true, encoding: .utf8
        )
        return nvdDir
    }

    /// A NAO-MGS import of the inline three-row table of `MetagenomicsImportServiceTests`, on a fixture taxdump, so the
    /// taxonomy install stays off the network. Returns the result folder.
    private func importNaoMgsRun(into imports: URL) async throws -> URL {
        let source = root.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        SAMPLE_A\tread2\t111\tACGTACGA\tFFFFFFFF\tACCN0002\t20\t8M\t8\t1\tFalse
        SAMPLE_A\tread3\t222\tACGTACGG\tFFFFFFFF\tACCN0003\t30\t8M\t8\t0\tTrue
        """.write(to: source, atomically: true, encoding: .utf8)
        let managed = root.appendingPathComponent("managed-databases", isDirectory: true)
        let registry = MetagenomicsDatabaseRegistry(
            baseDirectory: managed,
            catalog: MetagenomicsDatabaseInfo.builtInCatalog.filter { $0.tool == MetagenomicsTool.ncbiTaxonomy.rawValue },
            databaseInstaller: NCBITaxonomyFixture.installer(
                archive: managed.appendingPathComponent("taxdump.tar.gz"),
                scientificNames: [111: "Fixture virus alpha", 222: "Fixture virus beta"]
            )
        )
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-naomgs-import-tests.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try await MetagenomicsImportService.importNaoMgs(
            inputURL: source,
            outputDirectory: imports,
            sampleName: "SAMPLE_A",
            minIdentity: 90,
            fetchReferences: false,
            preferredName: nil,
            taxonomyRegistry: registry,
            progress: nil
        ).resultDirectory
    }
}
