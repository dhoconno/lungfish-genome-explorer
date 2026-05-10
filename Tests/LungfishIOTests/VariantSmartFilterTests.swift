import XCTest
import SQLite3
@testable import LungfishIO

final class VariantSmartFilterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantSmartFilterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParsesPerSampleComparisonPredicates() throws {
        let filter = try VariantSmartFilter.parse("Sample[NA12878].GT=1/1; Sample[NA12878].AF>=0.5; Sample[NA12878].DP>=30")

        XCTAssertEqual(filter.predicates.count, 3)
        XCTAssertEqual(filter.predicates[0].description, "Sample[NA12878].GT=1/1")
        XCTAssertEqual(filter.predicates[1].description, "Sample[NA12878].AF>=0.5")
        XCTAssertEqual(filter.predicates[2].description, "Sample[NA12878].DP>=30")
    }

    func testParsesCountAndSampleInequalityPredicates() throws {
        let filter = try VariantSmartFilter.parse("count(Sample[*].GT=1/1) >= 5; Sample[NA12878].GT != Sample[NA12879].GT")

        XCTAssertEqual(filter.predicates.count, 2)
        XCTAssertEqual(filter.predicates[0].description, "count(Sample[*].GT=1/1)>=5")
        XCTAssertEqual(filter.predicates[1].description, "Sample[NA12878].GT!=Sample[NA12879].GT")
    }

    func testCompilesLargeSamplePredicatesToIndexedGenotypeSQLShape() throws {
        let filter = try VariantSmartFilter.parse("count(Sample[*].GT=1/1) >= 5; Sample[NA12878].GT != Sample[NA12879].GT")
        let compiled = try filter.compileSQL(limit: 250)

        XCTAssertTrue(compiled.sql.contains("SELECT COUNT(*) FROM genotypes g"))
        XCTAssertTrue(compiled.sql.contains("g.variant_id = variants.id"))
        XCTAssertTrue(compiled.sql.contains("lhs.sample_name = ?"))
        XCTAssertTrue(compiled.sql.contains("lhs.variant_id = variants.id"))
        XCTAssertTrue(compiled.sql.contains("rhs.variant_id = lhs.variant_id"))
        XCTAssertTrue(compiled.sql.contains("rhs.sample_name = ?"))
        XCTAssertTrue(compiled.sql.contains("LIMIT 250"))
        XCTAssertEqual(compiled.bindings.count, 4)
    }

    func testQueriesPerSamplePredicatesAgainstVariantDatabase() throws {
        let database = try makeDatabase()

        let homAltNA12878 = try database.query(smartFilter: "Sample[NA12878].GT=1/1")
        XCTAssertEqual(homAltNA12878.map(\.variantID), ["rs100", "rs300"])

        let deepNA12878 = try database.query(smartFilter: "Sample[NA12878].DP>=30")
        XCTAssertEqual(deepNA12878.map(\.variantID), ["rs100", "rs300"])

        let highAfNA12878 = try database.query(smartFilter: "Sample[NA12878].AF>=0.5")
        XCTAssertEqual(highAfNA12878.map(\.variantID), ["rs100", "rs200", "rs300"])

        let twoHomAltSamples = try database.query(smartFilter: "count(Sample[*].GT=1/1) >= 2")
        XCTAssertEqual(twoHomAltSamples.map(\.variantID), ["rs100", "rs300"])

        let discordant = try database.query(smartFilter: "Sample[NA12878].GT != Sample[NA12879].GT")
        XCTAssertEqual(discordant.map(\.variantID), ["rs100"])
    }

    func testSmartFilterQueryStaysUnderOneSecondAtScale() throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_RUN_VARIANT_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUNGFISH_RUN_VARIANT_BENCHMARKS=1 to run the 1000-sample/100000-variant smart-filter benchmark.")
        }

        let database = try makeScaleDatabase(variantCount: 100_000, sampleCount: 1_000)
        _ = try database.query(smartFilter: "Sample[S0999].GT=1/1", limit: 5_000)

        let start = Date()
        let records = try database.query(smartFilter: "Sample[S0999].GT=1/1", limit: 5_000)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(records.count, 5_000)
        XCTAssertLessThan(elapsed, 1.0, "1000-sample/100000-variant smart-filter query took \(elapsed)s")
    }

    private func makeDatabase() throws -> VariantDatabase {
        let vcfURL = tempDir.appendingPathComponent("cohort.vcf")
        let dbURL = tempDir.appendingPathComponent("cohort.db")
        try cohortVCF.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, parseGenotypes: true)
        return try VariantDatabase(url: dbURL)
    }

    private func makeScaleDatabase(variantCount: Int, sampleCount: Int) throws -> VariantDatabase {
        let dbURL = tempDir.appendingPathComponent("smart-filter-scale.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        guard let db else {
            throw NSError(domain: "VariantSmartFilterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open benchmark database"])
        }
        defer { sqlite3_close(db) }

        let schema = """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
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
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            sample_name TEXT NOT NULL,
            genotype TEXT,
            allele1 INTEGER,
            allele2 INTEGER,
            is_phased INTEGER DEFAULT 0,
            depth INTEGER,
            genotype_quality INTEGER,
            allele_depths TEXT,
            raw_fields TEXT,
            PRIMARY KEY (variant_id, sample_name)
        );
        CREATE TABLE samples (
            name TEXT PRIMARY KEY,
            display_name TEXT,
            source_file TEXT,
            metadata TEXT
        );
        CREATE TABLE variant_info_defs (
            key TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            number TEXT NOT NULL,
            description TEXT
        );
        CREATE TABLE variant_info (
            variant_id INTEGER NOT NULL REFERENCES variants(id),
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (variant_id, key)
        );
        CREATE TABLE db_metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        INSERT INTO db_metadata(key, value) VALUES ('schema_version', '3');
        CREATE INDEX idx_variants_region ON variants(chromosome, position, end_pos);
        CREATE INDEX idx_genotypes_sample ON genotypes(sample_name);
        """
        try execSQL(schema, db: db)

        try execSQL("BEGIN", db: db)
        var sampleStmt: OpaquePointer?
        var variantStmt: OpaquePointer?
        var genotypeStmt: OpaquePointer?
        defer {
            sqlite3_finalize(sampleStmt)
            sqlite3_finalize(variantStmt)
            sqlite3_finalize(genotypeStmt)
        }
        sqlite3_prepare_v2(db, "INSERT INTO samples(name, display_name, source_file, metadata) VALUES (?, ?, 'scale.vcf', NULL)", -1, &sampleStmt, nil)
        sqlite3_prepare_v2(db, "INSERT INTO variants(chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count) VALUES ('chr1', ?, ?, ?, 'A', 'G', 'SNV', 60, 'PASS', NULL, ?)", -1, &variantStmt, nil)
        sqlite3_prepare_v2(db, "INSERT INTO genotypes(variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields) VALUES (?, 'S0999', ?, ?, ?, 0, 30, NULL, '0,30', 'GT:DP')", -1, &genotypeStmt, nil)

        for index in 0..<sampleCount {
            let name = String(format: "S%04d", index)
            sqliteBindText(sampleStmt, 1, name)
            sqliteBindText(sampleStmt, 2, name)
            XCTAssertEqual(sqlite3_step(sampleStmt), SQLITE_DONE)
            sqlite3_reset(sampleStmt)
            sqlite3_clear_bindings(sampleStmt)
        }

        for variantIndex in 1...variantCount {
            sqlite3_bind_int64(variantStmt, 1, Int64(variantIndex * 10))
            sqlite3_bind_int64(variantStmt, 2, Int64(variantIndex * 10 + 1))
            sqliteBindText(variantStmt, 3, "rsScale\(variantIndex)")
            sqlite3_bind_int64(variantStmt, 4, Int64(sampleCount))
            XCTAssertEqual(sqlite3_step(variantStmt), SQLITE_DONE)
            sqlite3_reset(variantStmt)
            sqlite3_clear_bindings(variantStmt)

            let isHomAlt = variantIndex % 2 == 0
            sqlite3_bind_int64(genotypeStmt, 1, Int64(variantIndex))
            sqliteBindText(genotypeStmt, 2, isHomAlt ? "1/1" : "0/1")
            sqlite3_bind_int64(genotypeStmt, 3, isHomAlt ? 1 : 0)
            sqlite3_bind_int64(genotypeStmt, 4, 1)
            XCTAssertEqual(sqlite3_step(genotypeStmt), SQLITE_DONE)
            sqlite3_reset(genotypeStmt)
            sqlite3_clear_bindings(genotypeStmt)
        }
        try execSQL("COMMIT", db: db)

        return try VariantDatabase(url: dbURL)
    }

    private func execSQL(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "VariantSmartFilterTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
    }

    private var cohortVCF: String {
        """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Depth">
        ##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allele depths">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNA12878\tNA12879\tNA12880
        chr1\t100\trs100\tA\tG\t60\tPASS\t.\tGT:DP:AD\t1/1:35:0,35\t0/1:32:16,16\t1/1:40:0,40
        chr1\t200\trs200\tC\tT\t50\tPASS\t.\tGT:DP:AD\t0/1:20:10,10\t0/1:22:11,11\t0/0:18:18,0
        chr1\t300\trs300\tG\tA\t70\tPASS\t.\tGT:DP:AD\t1/1:31:0,31\t1/1:34:0,34\t1/1:30:0,30
        """
    }
}
