// VCFImportModesPinTests.swift - What import vcf and its two finishing modes write, against the in-process core
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.07 (A64), QA 1, BIO 1, 3 and 7. Until M3 the Import Center built a VCF track by launching the
// app executable in up to three helper modes on a private copy of the track's database, the rows, the index build of
// an import left at `import_state = indexing` and the INFO table of an import whose INFO was skipped or whose
// materialization stopped. M1 pinned each helper mode against the core it ran. Since M3 the Import Center runs
// `lungfish-cli import vcf <vcf> --output-dir <bundle>` with `--resume` or `--materialize`, and these cases pin, for
// the sarscov2 fixture, that the command builds the rows the in-process core builds, what it records, and the mode
// the Import Center reads from a replaced track's database.

import ArgumentParser
import XCTest
import SQLite3
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

final class VCFImportModesPinTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try TestTempDirectory.make(prefix: "vcf-import-modes")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(tempDirectory)
    }

    // MARK: - The core's sequence against import vcf

    /// The core at the GUI's default profile (auto) takes the single pass for the fixture, then resumes an import left
    /// at `indexing`, as the helper did. `import vcf` builds the same rows into the bundle and records one step that
    /// names its own command.
    @MainActor
    func testTheCoreSequenceAndImportVCFBuildTheSameRows() async throws {
        let vcf = try copyFixtureVCFWithoutIndex()
        let viaHelper = tempDirectory.appendingPathComponent("core.db")
        _ = try VCFBundleVariantImport.createDatabase(
            vcfURL: vcf, outputDBURL: viaHelper, sourceFile: vcf.lastPathComponent, importProfile: .auto)
        if VariantDatabase.importState(at: viaHelper) == "indexing" {
            _ = try VariantDatabase.resumeImport(existingDBURL: viaHelper)
        }
        XCTAssertEqual(try metadataValue(viaHelper, key: "import_partition_mode"), "single-pass", "the fixture takes the single pass")

        let bundle = try makeBundle()
        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path], in: tempDirectory
        )
        XCTAssertNil(run.failure)
        let published = bundle.appendingPathComponent("variants/input.db")
        XCTAssertEqual(try Self.dump(published), try Self.dump(viaHelper))
        XCTAssertEqual(try metadataValue(published, key: "import_profile"), "auto")
        let track = try XCTUnwrap(try BundleManifest.load(from: bundle).variants.first)
        XCTAssertEqual(track.id, "input")
        XCTAssertEqual(track.name, "input.vcf")
        XCTAssertEqual(track.variantCount, 9)
        XCTAssertEqual(
            try Self.recordedCommands(in: bundle),
            [["lungfish-cli", "import", "vcf", vcf.path, "--output-dir", bundle.path]]
        )
    }

    /// `import vcf` at the ultra-low-memory profile builds in one pass in its own process, with the INFO table
    /// materialized and `import_partition_mode` = `single-pass`. The helper's fresh mode, gone since lane 12.07 M3, split the
    /// same import by chromosome with bcftools (`import_partition_mode` = `helper-subprocess-per-chromosome`).
    @MainActor
    func testImportVCFBuildsAnUltraLowMemoryImportInOnePass() async throws {
        let vcf = try copyFixtureVCFWithoutIndex()
        let bundle = try makeBundle()
        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--import-profile", "ultra-low-memory"],
            in: tempDirectory
        )
        XCTAssertNil(run.failure)
        let published = bundle.appendingPathComponent("variants/input.db")
        XCTAssertEqual(VariantDatabase.importState(at: published), "complete")
        XCTAssertEqual(try metadataValue(published, key: "import_partition_mode"), "single-pass")
        XCTAssertNotEqual(try Self.rows(published, "SELECT COUNT(*) FROM variant_info", quoted: false), ["0"])
    }

    /// Ruling ARCH-12.07-partition, step 1. `import vcf` at the ultra-low-memory profile reads every record in one pass,
    /// the record on the 515th header contig and the record on a contig the header does not list included. The helper's
    /// split, which the Import Center ran before lane 12.07, imported only the first 512 header contigs, 6 of these 8
    /// records (its real-tool case, run once in M2 and deleted with the helper in M3).
    @MainActor
    func testImportVCFImportsEveryRecordPastTheHeaderContigCap() async throws {
        let vcf = try Self.writeContigCapVCF(in: tempDirectory)
        let bundle = try Self.contigCapBundle(in: tempDirectory)
        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--import-profile", "ultra-low-memory"],
            in: tempDirectory
        )
        XCTAssertNil(run.failure)
        let published = bundle.appendingPathComponent("variants/contigs.db")
        XCTAssertEqual(try Self.rows(published, "SELECT COUNT(*) FROM variants", quoted: false), ["8"])
        XCTAssertEqual(try metadataValue(published, key: "import_partition_mode"), "single-pass")
    }

    // MARK: - The two modes of import vcf against the core's

    /// `import vcf --replace input --resume` on a track whose database stopped at `indexing` builds the database
    /// the core's resume builds, then the INFO the core's materialize fills, as the helper modes ran them.
    @MainActor
    func testImportVCFResumeLeavesTheDatabaseTheCoreModesLeave() async throws {
        let (bundle, vcf, published) = try bundleWithTrack(resumed: false)
        let viaHelper = tempDirectory.appendingPathComponent("core.db")
        try FileManager.default.copyItem(at: published, to: viaHelper)
        XCTAssertEqual(try VariantDatabase.resumeImport(existingDBURL: viaHelper), 9)
        _ = try VariantDatabase.materializeVariantInfo(existingDBURL: viaHelper)

        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--replace", "input", "--resume", "--format", "json"],
            in: tempDirectory
        )
        XCTAssertNil(run.failure)
        XCTAssertTrue(run.lines.last?.contains("9 variants imported") == true, "\(run.lines)")
        try assertSameRows(published, viaHelper)
        XCTAssertEqual(VariantDatabase.importState(at: published), "complete")
        let commands = try Self.recordedCommands(in: bundle)
        XCTAssertEqual(commands.first?.suffix(3), ["--replace", "input", "--resume"])
    }

    /// `import vcf --replace input --materialize` on a finished track whose INFO was skipped fills the INFO table the
    /// core's materialize fills.
    @MainActor
    func testImportVCFMaterializeLeavesTheDatabaseTheCoreModeLeaves() async throws {
        let (bundle, vcf, published) = try bundleWithTrack(resumed: true)
        let viaHelper = tempDirectory.appendingPathComponent("core.db")
        try FileManager.default.copyItem(at: published, to: viaHelper)
        _ = try VariantDatabase.materializeVariantInfo(existingDBURL: viaHelper)

        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--replace", "input", "--materialize"], in: tempDirectory
        )
        XCTAssertNil(run.failure)
        try assertSameRows(published, viaHelper)
        XCTAssertNotEqual(try Self.rows(published, "SELECT COUNT(*) FROM variant_info", quoted: false), ["0"])
    }

    /// A finishing mode refuses a database it cannot finish, as a usage error, and leaves the track as it was.
    @MainActor
    func testImportVCFResumeRefusesAFinishedTrack() async throws {
        let (bundle, vcf, published) = try bundleWithTrack(resumed: true)
        let before = try Self.dump(published)
        let run = try await ClassifierImportAppFixtures.runCLI(
            ["import", "vcf", vcf.path, "--output-dir", bundle.path, "--replace", "input", "--resume", "--format", "json"],
            in: tempDirectory
        )
        XCTAssertEqual((run.failure as? ExitCode)?.rawValue, CLIExitCode.inputError.exitCode.rawValue, "\(String(describing: run.failure))")
        XCTAssertTrue(run.lines.last?.contains("is at import state 'complete'") == true, "\(run.lines)")
        XCTAssertEqual(try Self.dump(published), before)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: published.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(".import-") }, []
        )
    }

    /// Lane 12.07 M2. The Import Center reads the mode from the replaced track's database as its helper sequence did. A
    /// new track and a finished track read the VCF again, a database stopped at `indexing` resumes, and one whose
    /// materialization stopped materializes.
    func testTheRowRunsTheModeTheTrackDatabaseNeeds() throws {
        let (bundle, _, database) = try bundleWithTrack(resumed: false)
        XCTAssertEqual(VCFImportCLICommand.mode(forTrackID: "input", replacing: nil, in: bundle), .fresh)
        XCTAssertEqual(VCFImportCLICommand.mode(forTrackID: "input-2", replacing: "input-2", in: bundle), .fresh)
        XCTAssertEqual(VCFImportCLICommand.mode(forTrackID: "input", replacing: "input", in: bundle), .resume)
        _ = try VariantDatabase.resumeImport(existingDBURL: database)
        XCTAssertEqual(VCFImportCLICommand.mode(forTrackID: "input", replacing: "input", in: bundle), .fresh)
        try VariantDatabase(url: database, readWrite: true).setMetadataValues(["materialize_state": "materializing"])
        XCTAssertEqual(VCFImportCLICommand.mode(forTrackID: "input", replacing: "input", in: bundle), .materialize)
    }

    // MARK: - The contig cap fixture

    /// The contigs whose records the cap fixture holds, two records on each of `c1` to `c3`, one on `c515` (past the
    /// 512 header contigs the split reads) and one on `cX`, which the header does not list.
    static let contigCapChromosomes = ["c1", "c2", "c3", "c515", "cX"]

    /// `contigs.vcf.gz`, a bgzipped VCF whose header lists 515 contigs `c1` to `c515` and two samples, with the eight
    /// records of `contigCapChromosomes`, each with INFO and genotypes.
    static func writeContigCapVCF(in folder: URL) throws -> URL {
        var text = """
        ##fileformat=VCFv4.2
        ##INFO=<ID=DP,Number=1,Type=Integer,Description="Depth">
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">

        """
        text += (1...515).map { "##contig=<ID=c\($0),length=1000>\n" }.joined()
        text += "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\n"
        let records = [
            ("c1", 10, "A", "G", "0/1:5", "1/1:7"), ("c1", 20, "C", "T", "0/0:6", "0/1:6"),
            ("c2", 15, "G", "A", "1/1:9", "0/1:3"), ("c2", 25, "T", "C", "0/1:4", "0/0:8"),
            ("c3", 30, "A", "C", "0/1:5", "0/1:5"), ("c3", 40, "G", "T", "0/0:2", "1/1:9"),
            ("c515", 50, "C", "G", "0/1:6", "0/0:6"), ("cX", 60, "T", "A", "1/1:7", "0/1:3"),
        ]
        for (index, record) in records.enumerated() {
            text += "\(record.0)\t\(record.1)\t.\t\(record.2)\t\(record.3)\t\(30 + index)\tPASS\t"
                + "DP=\(10 + index);AF=0.\(index + 1)\tGT:DP\t\(record.4)\t\(record.5)\n"
        }
        let url = folder.appendingPathComponent("contigs.vcf.gz")
        try bgzf(text).write(to: url)
        return url
    }

    /// A manifest-only reference bundle whose genome lists `contigCapChromosomes`.
    static func contigCapBundle(in folder: URL) throws -> URL {
        let bundle = folder.appendingPathComponent("ContigCap.lungfish/Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.contig-cap",
            source: SourceInfo(organism: "Synthetic", assembly: "contig-cap", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(1000 * contigCapChromosomes.count),
                chromosomes: contigCapChromosomes.enumerated().map { index, name in
                    ChromosomeInfo(name: name, length: 1000, offset: Int64(index * 1020), lineBases: 1000, lineWidth: 1001)
                }
            )
        ).save(to: bundle)
        return bundle
    }

    /// `text` as one BGZF block of stored deflate data and the BGZF end block, which htslib reads and indexes as it does
    /// bgzip output. The text fits one block (65,505 bytes).
    static func bgzf(_ text: String) -> Data {
        let payload = Array(text.utf8)
        precondition(payload.count <= 65_505, "one BGZF block")
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)] }
        func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xff) } }
        var crc: UInt32 = 0xffff_ffff
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        crc ^= 0xffff_ffff
        let deflate = [UInt8(1)] + le16(payload.count) + le16(~payload.count & 0xffff) + payload
        let header: [UInt8] = [31, 139, 8, 4, 0, 0, 0, 0, 0, 255, 6, 0, 66, 67, 2, 0]
        let block = header + le16(header.count + 2 + deflate.count + 8 - 1) + deflate + le32(crc) + le32(UInt32(payload.count))
        let end: [UInt8] = header + [27, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        return Data(block + end)
    }

    /// The rows of the tables on `chromosomes`, each keyed by the variant's chromosome, position, REF and ALT rather than
    /// its internal id, which follows file order in one pass and header order in the split.
    static func naturalKeyQueries(chromosomes: [String]) -> [String] {
        let on = "v.chromosome IN (\(chromosomes.map { "'\($0)'" }.joined(separator: ", ")))"
        let key = "v.chromosome, v.position, v.ref, v.alt"
        return [
            "SELECT \(key), v.end_pos, v.variant_id, v.variant_type, v.quality, v.filter, v.info, v.sample_count "
                + "FROM variants v WHERE \(on) ORDER BY \(key)",
            "SELECT \(key), g.sample_name, g.genotype, g.allele1, g.allele2, g.is_phased, g.depth, g.genotype_quality, "
                + "g.allele_depths, g.raw_fields FROM genotypes g JOIN variants v ON v.id = g.variant_id "
                + "WHERE \(on) ORDER BY \(key), g.sample_name",
            "SELECT name, display_name, metadata FROM samples ORDER BY name",
            "SELECT \(key), i.key, i.value FROM variant_info i JOIN variants v ON v.id = i.variant_id "
                + "WHERE \(on) ORDER BY \(key), i.key",
        ]
    }

    // MARK: - Helpers

    /// A bundle with the track `input` whose database stopped at `indexing` (`resumed` false) or finished with its
    /// INFO skipped (`resumed` true), as an import of the ultra-low-memory profile leaves it.
    func bundleWithTrack(resumed: Bool) throws -> (bundle: URL, vcf: URL, database: URL) {
        let vcf = try copyFixtureVCFWithoutIndex()
        let bundle = try makeBundle()
        let database = bundle.appendingPathComponent("variants/input.db")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let count = try VCFBundleVariantImport.createDatabase(
            vcfURL: vcf, outputDBURL: database, sourceFile: vcf.lastPathComponent, importProfile: .ultraLowMemory)
        if resumed { _ = try VariantDatabase.resumeImport(existingDBURL: database) }
        let track = VCFBundleVariantImport.makeTrackInfo(trackID: "input", vcfURL: vcf, variantCount: count)
        try BundleManifest.load(from: bundle).replacingVariantTrack(track).save(to: bundle)
        return (bundle, vcf, database)
    }

    func assertSameRows(_ lhs: URL, _ rhs: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Self.dump(lhs), try Self.dump(rhs), "rows", file: file, line: line)
        let indexes = "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name"
        XCTAssertEqual(try Self.rows(lhs, indexes), try Self.rows(rhs, indexes), "indexes", file: file, line: line)
    }

    var fixtures: URL {
        CLITestBinaryResolver.repositoryRoot(containing: #filePath)
            .appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
    }

    func copyFixtureVCFWithoutIndex() throws -> URL {
        let input = tempDirectory.appendingPathComponent("input.vcf.gz")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("test.vcf.gz"), to: input)
        return input
    }

    func metadataValue(_ url: URL, key: String) throws -> String? {
        try Self.rows(url, "SELECT value FROM db_metadata WHERE key = '\(key)'", quoted: false).first
    }

    /// The rows an import writes, without the source path or timestamps.
    static func dump(_ url: URL) throws -> String {
        try [
            "SELECT chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants ORDER BY id",
            "SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields FROM genotypes ORDER BY variant_id, sample_name",
            "SELECT name, display_name, metadata FROM samples ORDER BY name",
            "SELECT key, type, number, description FROM variant_info_defs ORDER BY key",
            "SELECT variant_id, key, value FROM variant_info ORDER BY variant_id, key",
        ].map { try rows(url, $0).joined(separator: "\n") }.joined(separator: "\n--\n")
    }

    static func rows(_ url: URL, _ query: String, quoted: Bool = true) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Could not open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return ["! \(query)"]
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { quoted ? String(cString: $0).debugDescription : String(cString: $0) } ?? "NULL"
            }.joined(separator: "|"))
        }
        return rows
    }

    func makeBundle() throws -> URL {
        let bundle = tempDirectory.appendingPathComponent("Project.lungfish/Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Reference",
            identifier: "bundle.reference",
            source: SourceInfo(organism: "Virus", assembly: "MT192765.1", database: "Test")
        ).save(to: bundle)
        return bundle
    }

    /// The command of each step of the one import record in the bundle.
    static func recordedCommands(in bundle: URL) throws -> [[String]] {
        let sidecars = try FileManager.default.subpathsOfDirectory(atPath: bundle.path)
            .filter { $0.hasSuffix(".json") && $0.lowercased().contains("provenance") }
        XCTAssertEqual(sidecars.count, 1, "one import record: \(sidecars)")
        let sidecar = bundle.appendingPathComponent(try XCTUnwrap(sidecars.first))
        let data = PortablePath.resolveJSON(try Data(contentsOf: sidecar), forFileAt: sidecar)
        return try ProvenanceEnvelopeReader.decodeCanonical(data).legacyWorkflowRun().steps.map(\.command)
    }
}
