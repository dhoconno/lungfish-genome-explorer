import XCTest
@testable import LungfishWorkflow

final class ViralReconParameterSchemaTests: XCTestCase {
    private let known: Set<String> = ["variant_caller", "min_mapped_reads", "skip_fastqc", "input"]

    func testKnownOverridableParameterIsAccepted() {
        let outcomes = ViralReconParameterSchema.validate(
            ["variant_caller": "bcftools"], knownParameters: known)
        XCTAssertEqual(outcomes, [.accepted])
    }

    func testUnknownParameterIsReportedByName() {
        let outcomes = ViralReconParameterSchema.validate(
            ["varient_caller": "bcftools"], knownParameters: known)
        XCTAssertEqual(outcomes, [.unknownParameter("varient_caller")])
    }

    func testStructuralParameterIsReportedEvenWhenKnownToTheSchema() {
        // `input` is a real pipeline parameter, but the wizard owns it.
        let outcomes = ViralReconParameterSchema.validate(
            ["input": "/tmp/x.csv"], knownParameters: known)
        XCTAssertEqual(outcomes, [.structural("input")])
    }

    func testLoadsParameterNamesFromNextflowSchema() throws {
        let schema = """
        {"$defs":{"input_output":{"properties":{
          "input":{"type":"string"},"outdir":{"type":"string"}}},
        "callers":{"properties":{"variant_caller":{"type":"string"}}}}}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-\(UUID().uuidString).json")
        try schema.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let names = try ViralReconParameterSchema.loadKnownParameters(from: url)

        XCTAssertTrue(names.contains("input"))
        XCTAssertTrue(names.contains("outdir"))
        XCTAssertTrue(names.contains("variant_caller"))
    }
}
