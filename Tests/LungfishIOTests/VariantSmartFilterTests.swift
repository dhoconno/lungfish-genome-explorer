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
        let gt = try VariantSmartFilter.parse("Sample[NA12878].GT=1/1")
        XCTAssertEqual(gt.sampleComparisons.first?.sample, "NA12878")
        XCTAssertEqual(gt.sampleComparisons.first?.field, .genotype)
        XCTAssertEqual(gt.sampleComparisons.first?.op, .eq)
        XCTAssertEqual(gt.sampleComparisons.first?.value, "1/1")

        let af = try VariantSmartFilter.parse("Sample[NA12878].AF>=0.5")
        XCTAssertEqual(af.sampleComparisons.first?.field, .alleleFrequency)
        XCTAssertEqual(af.sampleComparisons.first?.op, .gte)
        XCTAssertEqual(af.sampleComparisons.first?.value, "0.5")

        let dp = try VariantSmartFilter.parse("Sample[NA12878].DP>=30")
        XCTAssertEqual(dp.sampleComparisons.first?.field, .depth)
        XCTAssertEqual(dp.sampleComparisons.first?.op, .gte)
        XCTAssertEqual(dp.sampleComparisons.first?.value, "30")
    }

    func testParsesCountAndSampleInequalityPredicates() throws {
        let count = try VariantSmartFilter.parse("count(Sample[*].GT=1/1) >= 5")
        XCTAssertEqual(count.countComparisons.first?.predicate.sample, "*")
        XCTAssertEqual(count.countComparisons.first?.predicate.field, .genotype)
        XCTAssertEqual(count.countComparisons.first?.predicate.value, "1/1")
        XCTAssertEqual(count.countComparisons.first?.op, .gte)
        XCTAssertEqual(count.countComparisons.first?.count, 5)

        let inequality = try VariantSmartFilter.parse("Sample[NA12878].GT != Sample[NA12879].GT")
        XCTAssertEqual(inequality.sampleFieldComparisons.first?.lhs.sample, "NA12878")
        XCTAssertEqual(inequality.sampleFieldComparisons.first?.rhs.sample, "NA12879")
        XCTAssertEqual(inequality.sampleFieldComparisons.first?.field, .genotype)
        XCTAssertEqual(inequality.sampleFieldComparisons.first?.op, .neq)
    }

    func testCompilesToIndexedGenotypeSQLShape() throws {
        let filter = try VariantSmartFilter.parse("count(Sample[*].GT=1/1) >= 5")
        let compiled = filter.compileSQL(limit: 500)

        XCTAssertTrue(compiled.sql.contains("FROM variants"))
        XCTAssertTrue(compiled.sql.contains("FROM genotypes g"))
        XCTAssertTrue(compiled.sql.contains("g.variant_id = variants.id"))
        XCTAssertTrue(compiled.sql.contains("COUNT(*)"))
        XCTAssertTrue(compiled.sql.contains("LIMIT 500"))
        XCTAssertEqual(compiled.bindings.map(\.stringValue), ["1/1"])
    }

    func testQueriesPerSamplePredicatesAgainstVariantDatabase() throws {
        let db = try makeDatabase("""
        ##fileformat=VCFv4.3
        ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
        ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Read depth">
        ##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allelic depths">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNA12878\tNA12879\tNA12880
        chr1\t100\trs100\tA\tG\t50\tPASS\t.\tGT:DP:AD\t1/1:40:0,40\t0/1:32:16,16\t1/1:35:0,35
        chr1\t200\trs200\tC\tT\t50\tPASS\t.\tGT:DP:AD\t0/1:20:10,10\t0/1:31:15,16\t0/0:30:30,0
        chr1\t300\trs300\tG\tA\t50\tPASS\t.\tGT:DP:AD\t1/1:38:0,38\t1/1:42:0,42\t1/1:39:0,39
        """)

        XCTAssertEqual(try db.query(smartFilter: "Sample[NA12878].GT=1/1").map(\.variantID), ["rs100", "rs300"])
        XCTAssertEqual(try db.query(smartFilter: "Sample[NA12878].AF>=0.5").map(\.variantID), ["rs100", "rs200", "rs300"])
        XCTAssertEqual(try db.query(smartFilter: "Sample[NA12878].DP>=30").map(\.variantID), ["rs100", "rs300"])
        XCTAssertEqual(try db.query(smartFilter: "count(Sample[*].GT=1/1) >= 2").map(\.variantID), ["rs100", "rs300"])
        XCTAssertEqual(try db.query(smartFilter: "Sample[NA12878].GT != Sample[NA12879].GT").map(\.variantID), ["rs100"])
    }

    private func makeDatabase(_ vcf: String) throws -> VariantDatabase {
        let vcfURL = tempDir.appendingPathComponent("input.vcf")
        let dbURL = tempDir.appendingPathComponent("variants.db")
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return try VariantDatabase(url: dbURL)
    }
}
