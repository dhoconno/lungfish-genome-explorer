import XCTest
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

    private func makeDatabase() throws -> VariantDatabase {
        let vcfURL = tempDir.appendingPathComponent("cohort.vcf")
        let dbURL = tempDir.appendingPathComponent("cohort.db")
        try cohortVCF.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, parseGenotypes: true)
        return try VariantDatabase(url: dbURL)
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
